// 在网页自己的环境里运行（world: MAIN）：读页面里的播放器、抓 YouTube 播放器自己下载的字幕。
// 这里没有扩展的任何权限，只用 window.postMessage 把数据交给扩展的内容脚本（content.js 会再检查一遍）。
(() => {
  const TAG = '__aiquotaLyrics';
  const send = (what, data) => window.postMessage({ [TAG]: 1, what, ...data }, location.origin);

  if (location.hostname === 'www.youtube.com') {
    // 1) 抓播放器自己请求的 /api/timedtext：它带着 BotGuard 生成的 pot 参数，我们自己去请求只会拿到空内容。
    //    要在 document_start 装好，用户本来就开着字幕时播放器一初始化就会下载。
    const isTimedText = u => typeof u === 'string' && u.includes('/api/timedtext') && !u.includes('type=list');
    const emit = (url, text) => {
      if (!text || text[0] !== '{') return;               // 空内容：pot 缺失或过期
      let q;
      try { q = new URL(url, location.origin).searchParams; } catch { return; }
      send('track', { v: q.get('v') || '', text });
    };
    const xhrOpen = XMLHttpRequest.prototype.open;
    const xhrSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function (method, url) { this.__aqUrl = String(url); return xhrOpen.apply(this, arguments); };
    XMLHttpRequest.prototype.send = function () {
      if (isTimedText(this.__aqUrl)) this.addEventListener('load', () => {
        try { if (!this.responseType || this.responseType === 'text') emit(this.__aqUrl, this.responseText); } catch {}
      });
      return xhrSend.apply(this, arguments);
    };
    const pageFetch = window.fetch;
    window.fetch = async function (input) {
      const res = await pageFetch.apply(this, arguments);
      try {
        const url = typeof input === 'string' ? input : input?.url;
        if (isTimedText(url)) res.clone().text().then(t => emit(url, t), () => {});
      } catch {}
      return res;
    };

    // 2) 当前视频（YouTube 是单页应用，ytInitialPlayerResponse 换视频后会过期，用播放器自己的）
    const player = () => document.getElementById('movie_player');
    const currentResponse = () => {
      const pr = player()?.getPlayerResponse?.();
      const want = new URL(location.href).searchParams.get('v');
      return want && pr?.videoDetails?.videoId === want ? pr : null;
    };
    const tracksOf = pr => pr?.captions?.playerCaptionsTracklistRenderer?.captionTracks || [];
    let lastVideo = '';
    setInterval(() => {
      const pr = currentResponse();
      const vid = pr?.videoDetails?.videoId || '';
      if (!vid || vid === lastVideo) return;
      lastVideo = vid;
      send('video', { v: vid, title: pr.videoDetails.title || '', author: pr.videoDetails.author || '', hasTracks: tracksOf(pr).length > 0 });
    }, 700);

    // 3) 内容脚本别的办法都拿不到字幕时才会请求这里：临时打开字幕让播放器下载一次（画面上的字幕用 CSS 藏起来），
    //    拿到后关回去。用户自己开着字幕时不碰。
    let forcing = false;
    window.addEventListener('message', async (e) => {
      if (e.source !== window || e.origin !== location.origin) return;
      const d = e.data;
      if (!d || d[TAG] !== 2 || d.what !== 'force' || forcing) return;
      const p = player();
      const pr = currentResponse();
      if (!p?.setOption || !pr || pr.videoDetails.videoId !== d.v || p.isSubtitlesOn?.()) return;
      const list = tracksOf(pr);
      const prefs = ['zh-Hans', 'zh-CN', 'zh', 'en'];
      const pick = prefs.map(l => list.find(t => t.kind !== 'asr' && t.languageCode?.startsWith(l))).find(Boolean)
        || list.find(t => t.kind !== 'asr') || list.find(t => t.kind === 'asr');
      if (!pick) return;
      forcing = true;
      document.documentElement.classList.add('aiquota-hide-cc');
      try {
        p.loadModule('captions');
        let options = [];
        for (let i = 0; i < 40 && !options.length; i++) {
          await new Promise(r => setTimeout(r, 100));
          options = p.getOption('captions', 'tracklist', { includeAsr: true }) || [];
        }
        const track = options.find(x => x.languageCode === pick.languageCode && ((x.kind === 'asr') === (pick.kind === 'asr')))
          || { languageCode: pick.languageCode };
        p.setOption('captions', 'track', track);           // 播放器去下载 json3，被上面的钩子抓到
        await new Promise(r => setTimeout(r, 4000));
        p.setOption('captions', 'track', {});              // 关回去（原来就是关着的）
      } catch {}
      document.documentElement.classList.remove('aiquota-hide-cc');
      forcing = false;
    });
  }

  if (location.hostname === 'www.bilibili.com') {
    // B 站：当前放的是哪个视频的哪一 P。分 P、合集切换都在页内完成（player.reload），所以一直看着 cid。
    // 不能用 videoData.cid，那永远是第一 P。
    let lastKey = '';
    setInterval(() => {
      const m = window.player?.getManifest?.();
      const s = window.__INITIAL_STATE__ || {};
      const vi = s.videoInfo || {};                        // /festival/ 页面
      const vd = s.videoData || {};
      const cid = m?.cid ?? s.cid ?? vi.cid;
      const aid = m?.aid ?? s.aid ?? vi.aid;
      const bvid = m?.bvid ?? s.bvid ?? vi.bvid ?? vd.bvid;
      if (!cid || !aid || typeof cid === 'object') return;
      const key = `${bvid}|${cid}`;
      if (key === lastKey) return;
      lastKey = key;
      const pages = vd.pages || vi.pages || [];
      const page = pages.find(x => String(x.cid) === String(cid));
      send('ids', {
        aid: String(aid), bvid: String(bvid || ''), cid: String(cid),
        title: vd.title || vi.title || document.title,
        part: pages.length > 1 && page ? page.part || '' : '',
        seconds: +(page?.duration || vd.duration || 0),
        tname: vd.tname || '',
        tags: (s.tags || []).map(t => t.tag_name).filter(Boolean).slice(0, 20),
      });
    }, 700);
  }
})();
