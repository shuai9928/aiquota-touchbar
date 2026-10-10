// 扩展内容脚本（隔离环境）：拿到这个视频的字幕或歌词，跟着播放进度算出当前一句，交给后台转给 AIQuota。
// 页面（main.js 和页面自己的脚本）送来的一切都当成不可信的纯文本：只 JSON.parse，限制长度，从不当成代码或 HTML。
(() => {
  const AQ = globalThis.AQ;
  const TAG = '__aiquotaLyrics';
  const SITE = location.hostname === 'www.bilibili.com' ? 'bilibili' : 'youtube';
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const text = (s, n = 300) => String(s ?? '').replace(/[\u0000-\u001f\u007f]/g, ' ').slice(0, n);

  let cues = [];                         // [{start, end, text}]，毫秒
  let meta = { key: '', title: '', kind: 'subtitle' };
  let generation = 0;                    // 换视频时加一，丢掉旧视频还没回来的结果
  let media = null;                      // 最近发出播放事件的媒体元素（<video>，或 B 站的 <bwp-video>）
  let lastSig = '', lastBeat = 0, sentAny = false;

  // 扩展被重新加载后，旧页面里的脚本调用 chrome.runtime 会报 Extension context invalidated，忽略
  const send = (msg) => { try { chrome.runtime.sendMessage(msg).catch(() => {}); } catch {} };
  const ask = (msg) => { try { return chrome.runtime.sendMessage(msg).catch(() => null); } catch { return Promise.resolve(null); } };
  const toMain = (what, data) => window.postMessage({ [TAG]: 2, what, ...data }, location.origin);

  function reset(key) {
    generation++;
    meta = { key, title: '', kind: 'subtitle' };
    cues = [];
    lastSig = '';
    if (sentAny) { send({ type: 'none' }); sentAny = false; }
  }
  function setCues(key, list, title, kind) {
    if (key !== meta.key || !list?.length) return;
    cues = list;
    meta.title = text(title, 120);
    meta.kind = kind;
    lastSig = '';
    tick();
  }

  window.addEventListener('message', (e) => {
    if (e.source !== window || e.origin !== location.origin) return;    // 挡掉广告 iframe 之类发来的消息
    const d = e.data;
    if (!d || typeof d !== 'object' || d[TAG] !== 1) return;
    if (SITE === 'youtube') onYouTube(d); else onBilibili(d);
  });

  // ---------------- YouTube ----------------
  let yt = { v: '', title: '', got: false };
  const pendingTracks = new Map();       // 播放器可能在我们知道视频之前就下载了字幕

  function onYouTube(d) {
    if (d.what === 'video' && typeof d.v === 'string') {
      reset('yt:' + d.v);
      yt = { v: d.v, title: text(d.title, 120), got: false };
      const early = pendingTracks.get(d.v);
      pendingTracks.clear();
      if (early) useTrack(d.v, early);
      if (d.hasTracks && !yt.got) loadYouTube(d.v, generation);
    } else if (d.what === 'track' && typeof d.text === 'string' && d.text.length < 5_000_000 && typeof d.v === 'string') {
      if (d.v === yt.v) useTrack(d.v, d.text);
      else if (pendingTracks.size < 3) pendingTracks.set(d.v, d.text);
    }
  }
  function useTrack(v, body) {
    try {
      const list = AQ.json3ToCues(JSON.parse(body)).map(c => ({ ...c, text: text(c.text) }));
      if (list.length) { yt.got = true; setCues('yt:' + v, list, yt.title, 'subtitle'); }
    } catch {}
  }
  async function loadYouTube(v, gen) {
    await sleep(2500);                   // 用户本来开着字幕的话，播放器这会儿已经下载过、被抓到了
    if (gen !== generation || yt.got) return;
    const list = await youtubeAndroidTrack(v).catch(() => null);        // 不碰播放器的办法（非官方接口，随时可能失效）
    if (gen !== generation || yt.got) return;
    if (list?.length) { yt.got = true; setCues('yt:' + v, list, yt.title, 'subtitle'); return; }
    toMain('force', { v });              // 最后才让 main.js 临时打开字幕下载一次
  }
  async function youtubeAndroidTrack(v) {
    const r = await fetch('https://www.youtube.com/youtubei/v1/player?prettyPrint=false', {
      method: 'POST', credentials: 'omit', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ context: { client: { clientName: 'ANDROID', clientVersion: '20.10.38', androidSdkVersion: 30, hl: 'en' } }, videoId: v }),
    });
    const pr = await r.json();
    const tracks = pr?.captions?.playerCaptionsTracklistRenderer?.captionTracks || [];
    const prefs = ['zh-Hans', 'zh-CN', 'zh', 'en'];
    const pick = prefs.map(l => tracks.find(t => t.kind !== 'asr' && t.languageCode?.startsWith(l))).find(Boolean)
      || tracks.find(t => t.kind !== 'asr') || tracks.find(t => t.kind === 'asr');
    if (!pick?.baseUrl || /[?&]exp=[^&]*(xpe|xpv)/.test(pick.baseUrl)) return null;
    const u = new URL(pick.baseUrl, 'https://www.youtube.com');
    if (u.hostname !== 'www.youtube.com') return null;
    u.searchParams.set('fmt', 'json3');
    const body = await (await fetch(u, { credentials: 'omit' })).text();
    return body && body[0] === '{' ? AQ.json3ToCues(JSON.parse(body)).map(c => ({ ...c, text: text(c.text) })) : null;
  }

  // ---------------- Bilibili ----------------
  const getJSON = (u, credentials = 'include') => fetch(u, { credentials }).then(r => r.json());
  const https = u => String(u || '').replace(/^(https?:)?\/\//, 'https://');
  const isAI = s => s.type === 1 || String(s.lan || '').startsWith('ai-');
  const zhFirst = (a, b) => (/^(zh|ai-zh)/i.test(a.lan) ? 0 : 5) - (/^(zh|ai-zh)/i.test(b.lan) ? 0 : 5);
  const songTitle = (t, a) => t ? (a ? `${t} · ${a}` : t) : '';
  // 只有像是歌的视频才按歌名上网查，普通视频的标题不发出去
  const looksLikeMusic = (d, bgm) => !!bgm?.music_id
    || /音乐|翻唱|MV|演奏|VOCALOID|UTAU|唱见/.test(d.tname || '')
    || /《[^》]+》|翻唱|\bcover\b|\bMV\b|歌曲|原唱/i.test(d.title || '');

  async function onBilibili(d) {
    if (d.what !== 'ids' || typeof d.cid !== 'string' || typeof d.aid !== 'string') return;
    if (!/^\d+$/.test(d.cid) || !/^\d+$/.test(d.aid)) return;
    const key = `bili:${d.bvid}:${d.cid}`;
    if (key === meta.key) return;
    reset(key);
    const gen = generation;
    const info = {
      aid: d.aid, cid: d.cid, bvid: text(d.bvid, 20),
      title: text(d.title, 200), part: text(d.part, 200), seconds: Math.max(0, +d.seconds || 0),
      tname: text(d.tname, 40), tags: Array.isArray(d.tags) ? d.tags.map(t => text(t, 40)).slice(0, 20) : [],
    };
    const got = await loadBilibili(info, gen).catch(() => null);
    if (gen === generation && got) setCues(key, got.cues, got.title, got.kind);
  }

  async function loadBilibili(d, gen) {
    const pv = await getJSON(`https://api.bilibili.com/x/player/wbi/v2?aid=${d.aid}&cid=${d.cid}`).catch(() => null);
    const bgm = pv?.data?.bgm_info || null;
    let subs = (pv?.data?.subtitle?.subtitles || []).filter(s => s.subtitle_url);
    // 1) 人工字幕（CC）最准，歌曲的 CC 往往就是歌词
    const human = subs.filter(s => !isAI(s)).sort(zhFirst)[0];
    if (human) {
      const list = await biliSubtitle(human);
      if (list?.length) return { cues: list, title: d.title, kind: 'subtitle' };
    }
    // 2) 像是歌：先用 B 站自己的官方歌词（只在就是官方 MV 时时间才对得上），再按歌名上网查
    if (looksLikeMusic(d, bgm)) {
      let bgmTitle = '', bgmArtist = '';
      if (bgm?.music_id) {
        const detail = (await getJSON(`https://api.bilibili.com/x/copyright-music-publicity/bgm/detail?music_id=${encodeURIComponent(bgm.music_id)}`).catch(() => null))?.data;
        bgmTitle = text(String(detail?.music_title || '').replace(/^发现《(.+)》$/, '$1'), 80);
        bgmArtist = text(detail?.origin_artist, 80);
        if (detail?.mv_lyric && detail.mv_bvid && detail.mv_bvid === d.bvid) {
          const lrc = await fetch(https(detail.mv_lyric), { credentials: 'omit' }).then(r => r.text()).catch(() => '');
          const list = lrc ? AQ.lrcToCues(lrc) : [];
          if (AQ.lyricLineCount(list) >= 5) return { cues: list, title: songTitle(bgmTitle, bgmArtist), kind: 'lyrics' };
        }
      }
      if (gen !== generation) return null;
      const found = await ask({ type: 'lookup', bvid: d.bvid, cid: d.cid, title: d.part || d.title,
                                bgmTitle, bgmArtist, tags: d.tags, durationSec: d.seconds });
      if (found?.lrc) {
        const list = AQ.lrcToCues(found.lrc, found.timeScale || 1);
        if (AQ.lyricLineCount(list) >= 5) return { cues: list, title: songTitle(found.song || bgmTitle, found.artist || bgmArtist), kind: 'lyrics' };
      }
    }
    // 3) AI 字幕（歌曲的 AI 字幕常听错词，所以放在最后）。登录后 wbi/v2 里就有；没有时试一下未公开的 dm/view
    if (!subs.length) {
      const dv = await getJSON(`https://api.bilibili.com/x/v2/dm/view?type=1&oid=${d.cid}&pid=${d.aid}`).catch(() => null);
      subs = (dv?.data?.subtitle?.subtitles || []).filter(s => s.subtitle_url);
    }
    const best = [...subs.filter(s => !isAI(s)).sort(zhFirst), ...subs.filter(isAI).sort(zhFirst)][0];
    if (best) {
      const list = await biliSubtitle(best);
      if (list?.length) return { cues: list, title: d.title, kind: 'subtitle' };
    }
    return null;
  }
  async function biliSubtitle(s) {
    const url = new URL(https(s.subtitle_url));
    if (!/(^|\.)hdslb\.com$|(^|\.)bilibili\.com$/.test(url.hostname)) return null;
    const j = await fetch(url, { credentials: 'omit' }).then(r => r.json());
    return (j?.body || []).map(c => ({ start: (+c.from || 0) * 1000, end: (+c.to || 0) * 1000, text: text(String(c.content || '').replace(/\n/g, ' ')) }));
  }

  // ---------------- 跟着播放进度 ----------------
  // YouTube 首页、侧栏的悬停预览和 Shorts 也是 <video>：只认主播放器，不然会拿上一个视频的字幕对着预览的进度报「在放」
  const mainPlayer = t => SITE !== 'youtube' || !!t.closest?.('#movie_player');
  for (const type of ['timeupdate', 'play', 'playing', 'pause', 'seeked', 'ratechange', 'ended', 'emptied']) {
    document.addEventListener(type, (e) => {
      const t = e.target;                // 媒体事件不冒泡，在捕获阶段接
      if (t && typeof t.currentTime === 'number' && typeof t.paused === 'boolean' && mainPlayer(t)) media = t;
      tick();
    }, true);
  }
  setInterval(tick, 250);                // 有声音的后台标签页基本不被节流；requestAnimationFrame 在后台不跑，不能用
  window.addEventListener('pagehide', () => { if (sentAny) send({ type: 'none' }); });

  function currentMedia() {
    if (media?.isConnected) return media;
    return SITE === 'youtube'
      ? document.querySelector('#movie_player video.html5-main-video')
      : document.querySelector('.bpx-player-video-wrap video, .bpx-player-video-wrap bwp-video, video');
  }
  function tick() {
    if (!cues.length) return;
    // YouTube 换到下一个视频时地址先变，字幕要等 main.js 下一次报（最多 0.7 秒）才换：这段时间别拿旧字幕对新视频的进度。
    // 地址里没有 v（小窗播放时在首页）照常报
    if (SITE === 'youtube') {
      const want = new URLSearchParams(location.search).get('v');
      if (want && want !== yt.v) return;
    }
    const v = currentMedia();
    if (!v) return;
    const ad = SITE === 'youtube' && !!document.getElementById('movie_player')?.classList.contains('ad-showing');
    const ms = v.currentTime * 1000 + 150;             // 提前 150 毫秒，抵掉送到触控栏的延迟
    const i = ad ? -1 : AQ.cueIndex(cues, ms);
    const line = i >= 0 && ms < cues[i].end ? cues[i].text : '';
    let next = '';
    for (let k = i + 1; k < cues.length && k <= i + 4; k++) if (k >= 0 && cues[k].text) { next = cues[k].text; break; }
    const playing = !v.paused && !v.ended && !ad;
    const sig = `${line}\u0000${next}\u0000${playing}`;
    const now = Date.now();
    if (sig === lastSig && (!playing || now - lastBeat < 1000)) return;   // 在放时每秒报一次，停着就不再报
    lastSig = sig;
    lastBeat = now;
    sentAny = true;
    send({ type: 'lyric', title: meta.title, kind: meta.kind, line, next, playing });
  }
})();
