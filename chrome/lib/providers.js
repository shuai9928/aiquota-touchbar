// 在线歌词来源，只在后台 service worker 里用（有 host_permissions，不受网页 CORS 限制）。
// 只发歌名、歌手和时长，不带任何账号或浏览记录。
(() => {
  const AQ = (globalThis.AQ = globalThis.AQ || {});
  // LRCLIB 要求标明客户端；浏览器里改不了 User-Agent，用它认的 Lrclib-Client 头
  const LRCLIB_HDR = { 'Lrclib-Client': 'AIQuota-TouchBar-Lyrics 1.0 (personal use)' };
  const TIMEOUT = 8000;
  const get = (url, opts = {}) => fetch(url, { ...opts, credentials: 'omit', signal: AbortSignal.timeout(TIMEOUT) });

  class RateLimited extends Error {
    constructor(retryAfter) { super('rate limited'); this.retryAfter = retryAfter; }
  }

  // ---- LRCLIB：/api/get 在服务端按 ±2 秒时长精确匹配；/api/search 模糊搜，时长要自己核对
  async function lrclibGet(title, artist, durSec) {
    const u = 'https://lrclib.net/api/get?' + new URLSearchParams({ track_name: title, artist_name: artist, duration: String(Math.round(durSec)) });
    const r = await get(u, { headers: LRCLIB_HDR });
    if (r.status === 429) throw new RateLimited(+r.headers.get('Retry-After') || 60);
    if (!r.ok) return null;
    const j = await r.json();
    return j.syncedLyrics ? { provider: 'lrclib', id: j.id, title: j.trackName, artist: j.artistName, durationSec: j.duration, lrc: j.syncedLyrics } : null;
  }
  async function lrclibSearch(title, artist) {
    const q = artist ? artist + ' ' + title : title;          // 中间要有空格，连着写搜不到
    const r = await get('https://lrclib.net/api/search?' + new URLSearchParams({ q }), { headers: LRCLIB_HDR });
    if (r.status === 429) throw new RateLimited(+r.headers.get('Retry-After') || 60);
    if (!r.ok) return [];
    return (await r.json()).filter(x => x.syncedLyrics && !x.instrumental)
      .map(x => ({ provider: 'lrclib', id: x.id, title: x.trackName, artist: x.artistName, durationSec: x.duration, synced: true, lrc: x.syncedLyrics }));
  }

  // ---- 网易云：不用登录、Cookie 或 Referer；code 不是 200（-460/-462）就放弃，不重试
  async function neteaseSearch(kw, limit = 10) {
    const r = await get('https://music.163.com/api/cloudsearch/pc?' + new URLSearchParams({ s: kw, type: '1', limit: String(limit), offset: '0' }));
    const j = await r.json();
    if (j.code !== 200) return [];
    return (j.result?.songs || []).map(s => ({ provider: 'netease', id: s.id, title: s.name, artist: (s.ar || []).map(a => a.name).join('/'), durationSec: s.dt / 1000, synced: true }));
  }
  async function neteaseLyric(id) {
    const j = await (await get(`https://music.163.com/api/song/lyric?id=${id}&lv=1&kv=1&tv=-1`)).json();
    if (j.code !== 200 || j.pureMusic || !/\[\d+:\d+/.test(j.lrc?.lyric || '')) return null;
    return j.lrc.lyric;
  }

  // ---- 酷狗：关键词要「歌手 - 歌名」，带时长；有周杰伦这类网易云没有的版权
  async function kugouSearch(title, artist, durSec) {
    const keyword = artist ? `${artist} - ${title}` : title;
    const j = await (await get('https://lyrics.kugou.com/search?' + new URLSearchParams({ ver: '1', man: 'yes', client: 'pc', keyword, duration: String(Math.round(durSec * 1000)), hash: '' }))).json();
    return (j.candidates || []).map(c => ({ provider: 'kugou', id: c.id, accesskey: c.accesskey, title: c.song, artist: c.singer, durationSec: c.duration / 1000, synced: true }));
  }
  async function kugouLrc(id, accesskey) {
    const j = await (await get(`https://lyrics.kugou.com/download?ver=1&client=pc&id=${id}&accesskey=${accesskey}&fmt=lrc&charset=utf8`)).json();
    if (!j.content) return null;
    const bytes = Uint8Array.from(atob(j.content), ch => ch.charCodeAt(0));   // base64 → UTF-8（直接 atob 会乱码）
    return new TextDecoder('utf-8').decode(bytes);
  }

  Object.assign(AQ, { RateLimited, lrclibGet, lrclibSearch, neteaseSearch, neteaseLyric, kugouSearch, kugouLrc });
})();
