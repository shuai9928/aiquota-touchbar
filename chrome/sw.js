// 后台 service worker：
// 1) 把内容脚本报来的当前一句转给 AIQuota（native messaging，只有这个扩展能启动那边的桥，网页碰不到）；
// 2) 按歌名在网上查带时间轴的歌词（LRCLIB → 网易云 → 酷狗），只发歌名、歌手和时长。
importScripts('lib/lrc.js', 'lib/title.js', 'lib/match.js', 'lib/providers.js');

const HOST = 'local.aiquota.lyrics';
const OK_HOSTS = new Set(['www.bilibili.com', 'www.youtube.com']);
// importScripts 进来的脚本和这里共用一个全局作用域：顶层名字不能和 lib/ 里的重复（lib/title.js 有 clean），
// 重复了整个后台直接起不来。
const text = (s, n = 300) => String(s ?? '').replace(/[\u0000-\u001f\u007f]/g, ' ').slice(0, n);

// ---------------- 转给 AIQuota ----------------
let port = null;
let idleTimer = null;
let current = null;                      // 正在放的标签页 {tabId, ts}

function getPort() {
  if (port) return port;
  port = chrome.runtime.connectNative(HOST);
  port.onDisconnect.addListener(() => { void chrome.runtime.lastError; port = null; });
  return port;
}
function post(msg) {
  try { getPort().postMessage(msg); } catch { port = null; }
  // 一分钟没有新消息就断开：开着的端口会让后台和那边的桥一直活着
  clearTimeout(idleTimer);
  idleTimer = setTimeout(() => { try { port?.disconnect(); } catch {} port = null; }, 60_000);
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (sender.id !== chrome.runtime.id || !sender.tab || !msg || typeof msg !== 'object') return;
  let host = '';
  try { host = new URL(sender.url || sender.tab.url).hostname; } catch {}
  if (!OK_HOSTS.has(host)) return;

  if (msg.type === 'lookup') {
    resolveLyrics(msg).then(sendResponse, () => sendResponse(null));
    return true;                         // 异步回复
  }
  const tabId = sender.tab.id;
  const now = Date.now();
  if (msg.type === 'lyric') {
    // 同时有几个标签页在放时只跟最近开始放的那个；它停下 3 秒后别的标签页才能接手
    if (msg.playing) {
      if (current && current.tabId !== tabId && now - current.ts < 3000) return;
      current = { tabId, ts: now };
    } else if (!current || current.tabId !== tabId) {
      return;
    }
    post({
      type: 'lyric', site: host === 'www.bilibili.com' ? 'bilibili' : 'youtube',
      title: text(msg.title, 120), line: text(msg.line), next: text(msg.next),
      kind: msg.kind === 'lyrics' ? 'lyrics' : 'subtitle', playing: !!msg.playing,
    });
  } else if (msg.type === 'none' && current?.tabId === tabId) {
    current = null;
    post({ type: 'none' });
  }
});

chrome.tabs.onRemoved.addListener((tabId) => {
  if (current?.tabId === tabId) { current = null; post({ type: 'none' }); }
});

// ---------------- 按歌名查歌词 ----------------
const sleep = ms => new Promise(r => setTimeout(r, ms));
let lrclibPausedUntil = 0;               // 被 LRCLIB 限流（429）后按 Retry-After 停一阵

/// info: {bvid, cid, title, bgmTitle, bgmArtist, tags[], durationSec}；结果（包括没找到）按 bvid:cid 缓存，没找到的一周后再试
async function resolveLyrics(info) {
  const durationSec = +info.durationSec || 0;
  if (!info.bvid || !info.cid || durationSec < 30) return null;
  const ck = `lyr:${text(info.bvid, 20)}:${text(info.cid, 20)}`;
  const cached = (await chrome.storage.local.get(ck))[ck];
  if (cached && (cached.result || Date.now() - cached.at < 7 * 86400e3)) return cached.result;
  let result;
  try {
    result = await lookup({ ...info, title: text(info.title, 200), durationSec });
  } catch (e) {
    if (e instanceof AQ.RateLimited) lrclibPausedUntil = Date.now() + Math.min(3600, e.retryAfter) * 1000;
    return null;                         // 限流或出错时不缓存，下次再试
  }
  await chrome.storage.local.set({ [ck]: { at: Date.now(), result } });
  return result;
}

async function lookup(info) {
  const dur = info.durationSec;
  const queries = [];
  if (info.bgmTitle) {
    const a = text(info.bgmArtist, 80);
    queries.push({ title: text(info.bgmTitle, 80), artist: a, artistVariants: a ? artistVariants(a) : [], why: 'bgm' });
  }
  queries.push(...parseBiliTitle(info.title, { tags: (info.tags || []).map(t => text(t, 40)) }));
  for (const q of queries.slice(0, 3)) {
    // 1) LRCLIB 精确查：服务端按 ±2 秒的时长匹配，一个歌手写法一个请求
    if (Date.now() > lrclibPausedUntil) {
      for (const a of q.artistVariants || []) {
        const hit = await AQ.lrclibGet(q.title, a, dur).catch(e => { if (e instanceof AQ.RateLimited) throw e; return null; });
        if (hit && AQ.lyricLineCount(AQ.lrcToCues(hit.lrc)) >= 5) return found(hit.lrc, 1, hit);
        await sleep(250);
      }
    }
    // 2) 三家一起模糊搜，本地按歌名、歌手、时长打分（时长差太多的不要，翻唱、现场版的时间轴对不上）
    const artist = (q.artistVariants || [])[1] || (q.artistVariants || [])[0] || '';
    const kw = (artist + ' ' + q.title).trim();
    const cands = [
      ...(Date.now() > lrclibPausedUntil ? await AQ.lrclibSearch(q.title, artist).catch(() => []) : []),
      ...await AQ.neteaseSearch(kw).catch(() => []),
      ...await AQ.kugouSearch(q.title, artist, dur).catch(() => []),
    ];
    const { best } = pickBest(q, cands, dur, info.title);
    if (!best) continue;
    let lrc = best.lrc;
    if (best.provider === 'netease') lrc = await AQ.neteaseLyric(best.id).catch(() => null);
    if (best.provider === 'kugou') lrc = await AQ.kugouLrc(best.id, best.accesskey).catch(() => null);
    if (lrc && AQ.lyricLineCount(AQ.lrcToCues(lrc)) >= 5) return found(lrc, best.timeScale || 1, best);
  }
  return null;
}

const found = (lrc, timeScale, c) => ({
  lrc: String(lrc).slice(0, 200_000), timeScale, provider: c.provider,
  song: text(c.title, 80), artist: text(c.artist, 80),
});
