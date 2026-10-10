// Chrome 歌词扩展（chrome/）的脚本冒烟测试，用系统自带的 jsc 跑，不用装 node：
//   jsc tests/ChromeScriptsTest.js -- ../chrome
// 按 manifest 把每组脚本放进一个新的全局环境依次加载，和 Chrome 一样：同一组共用一个全局作用域，
// 顶层名字重复（比如 sw.js 和 lib/title.js 各有一个 const clean）Chrome 会拒绝运行整组，后台起不来就什么都没有。
// 再用假的 chrome.* 和 fetch 走一遍后台的两条路：把当前一句转给 AIQuota、按歌名查歌词。
const dir = arguments[0];
let checks = 0;
function check(value, label) {
  if (!value) throw new Error('FAIL: ' + label);
  checks++;
}
const manifest = JSON.parse(readFile(dir + '/manifest.json'));

// 每个环境都有的：定时器手动推进（jsc 没有 clearTimeout，也别让 60 秒的空闲断开拖住退出）
const COMMON = `
  var timers = [];
  var setTimeout = (f) => { timers.push(f); return timers.length; };
  var clearTimeout = () => {};
  var setInterval = () => 0;
  function settle() {
    for (let i = 0; i < 100; i++) {
      drainMicrotasks();
      const due = timers.splice(0);
      if (!due.length) return;
      for (const f of due) if (typeof f === 'function') f();
    }
  }
  function loadAll(files) { for (const f of files) load(${JSON.stringify(dir)} + '/' + f); }
`;

function realm(setup) {
  const r = $.createRealm();
  r.evalScript(COMMON + setup);
  return r;
}
function loads(r, files, label) {
  try {
    r.evalScript(`loadAll(${JSON.stringify(files)})`);
    check(true, label);
  } catch (e) {
    check(false, `${label}：${e}`);
  }
}

// ---------------- 后台 service worker ----------------
const LRC = ['[00:01.00]作词：林俊杰', '[00:10.00]风到这里就是粘', '[00:14.00]粘住过客的思念', '[00:18.00]雨到了这里缠成线',
             '[00:22.00]缠着我们留恋人世间', '[00:26.00]你在身边就是缘', '[00:30.00]缘分写在三生石上面'].join('\n');
const sw = realm(`
  var self = globalThis;
  var listeners = {}, posted = [], stored = {}, fetched = [];
  function importScripts(...files) { loadAll(files); }
  var chrome = {
    runtime: {
      id: 'ext', lastError: undefined,
      onMessage: { addListener(f) { listeners.message = f; } },
      connectNative(name) { return { name, postMessage(m) { posted.push(m); }, disconnect() {}, onDisconnect: { addListener() {} } }; },
    },
    tabs: { onRemoved: { addListener(f) { listeners.removed = f; } } },
    storage: { local: { get: async (k) => ({ [k]: stored[k] }), set: async (o) => { Object.assign(stored, o); } } },
  };
  class URLSearchParams {
    constructor(o) { this.o = o; }
    toString() { return Object.entries(this.o).map(([k, v]) => encodeURIComponent(k) + '=' + encodeURIComponent(v)).join('&'); }
  }
  class URL {
    constructor(u) {
      const m = /^https?:\\/\\/([^/?#:]+)/.exec(String(u));
      if (!m) throw new TypeError('Invalid URL');
      this.hostname = m[1];
    }
  }
  var AbortSignal = { timeout: () => undefined };
  // 只有 LRCLIB 精确查有结果，其余一律当成断网
  async function fetch(url) {
    fetched.push(String(url));
    if (String(url).startsWith('https://lrclib.net/api/get?')) {
      return { ok: true, status: 200, headers: { get: () => null },
               json: async () => ({ id: 1, trackName: '江南\\u0007', artistName: '林俊杰', duration: 267, syncedLyrics: ${JSON.stringify(LRC)} }) };
    }
    throw new TypeError('offline');
  }
`);
loads(sw, [manifest.background.service_worker], `后台 ${manifest.background.service_worker} 连同 importScripts 的 lib 一起加载`);
for (const fn of ['parseBiliTitle', 'artistVariants', 'pickBest', 'AQ.lrcToCues', 'AQ.lrclibGet', 'AQ.neteaseSearch', 'AQ.kugouSearch'])
  check(sw.evalScript(`typeof ${fn}`) === 'function', `后台能用 ${fn}`);
check(sw.evalScript('typeof listeners.message') === 'function', '后台装好了消息监听');

sw.evalScript(`
  var bili = { id: 'ext', url: 'https://www.bilibili.com/video/BV1EC41147U1/', tab: { id: 7, url: 'https://www.bilibili.com/video/BV1EC41147U1/' } };
  listeners.message({ type: 'lyric', title: '江南\\u0000', line: '风到这里就是粘', next: '粘住过客的思念', kind: 'lyrics', playing: true }, bili);
  listeners.message({ type: 'lyric', title: 'x', line: 'x', next: '', kind: 'subtitle', playing: true },
                    { id: 'ext', url: 'https://evil.example/', tab: { id: 8, url: 'https://evil.example/' } });
  listeners.message({ type: 'lyric', title: 'x', line: 'x', next: '', kind: 'subtitle', playing: true }, { ...bili, id: 'other' });
  settle();
`);
const posted = JSON.parse(sw.evalScript('JSON.stringify(posted)'));
check(posted.length === 1, '只转发本扩展、B 站/YouTube 页面来的消息');
check(posted[0].type === 'lyric' && posted[0].site === 'bilibili' && posted[0].kind === 'lyrics' && posted[0].playing === true, '转发的字段');
check(posted[0].title === '江南 ' && posted[0].line === '风到这里就是粘' && posted[0].next === '粘住过客的思念', '转发前去掉控制字符');

sw.evalScript(`
  var answer = 'pending';
  var isAsync = listeners.message({ type: 'lookup', bvid: 'BV1EC41147U1', cid: '1430863026', title: '江南', bgmTitle: '江南', bgmArtist: '林俊杰',
                                  tags: ['林俊杰', '歌曲'], durationSec: 267 }, bili, (r) => { answer = r; });
  settle();
`);
check(sw.evalScript('isAsync') === true, '查歌词是异步回复');
const answer = JSON.parse(sw.evalScript('JSON.stringify(answer)'));
check(answer && answer.provider === 'lrclib' && answer.song === '江南 ' && answer.artist === '林俊杰' && answer.timeScale === 1, '按 BGM 歌名歌手查到 LRCLIB 的歌词');
check(answer.lrc.includes('缘分写在三生石上面'), '带回完整的 LRC');
check(sw.evalScript(`fetched.every(u => /^https:\\/\\/(lrclib\\.net|music\\.163\\.com|lyrics\\.kugou\\.com)\\//.test(u))`) === true, '只请求三家歌词网站');
check(sw.evalScript(`stored['lyr:BV1EC41147U1:1430863026']?.result?.provider`) === 'lrclib', '结果按视频缓存');

// ---------------- 内容脚本（每个网站、每一组各自一个全局环境） ----------------
const HOSTS = ['www.bilibili.com', 'www.youtube.com'];
for (const cs of manifest.content_scripts) {
  for (const host of HOSTS.filter(h => cs.matches.some(m => m.includes('//' + h + '/')))) {
    const r = realm(`
      var location = { hostname: '${host}', origin: 'https://${host}', href: 'https://${host}/' };
      var window = globalThis;
      window.addEventListener = () => {};
      window.postMessage = () => {};
      var document = { addEventListener() {}, querySelector() { return null; }, getElementById() { return null; },
                       documentElement: { classList: { add() {}, remove() {} } } };
      var chrome = { runtime: { sendMessage: () => Promise.resolve(null) } };
      function XMLHttpRequest() {}
      XMLHttpRequest.prototype.open = function () {};
      XMLHttpRequest.prototype.send = function () {};
      window.fetch = async () => ({});
    `);
    loads(r, cs.js, `${host} 上的 ${cs.world === 'MAIN' ? '页面环境' : '扩展环境'}脚本 ${cs.js.join(' + ')}`);
  }
}

// ---------------- YouTube：只跟主播放器 ----------------
// 看过带字幕的视频 X 以后，首页的悬停预览、Shorts 也是 <video>：不能拿 X 的字幕对着它们报「在放」（触控栏会带着旧字幕一弹一收）；
// 播放列表换到下一个视频、地址已经变了而 main.js 还没报新视频时，也别拿旧字幕报
const isolated = manifest.content_scripts.find(cs => cs.world !== 'MAIN' && cs.matches.some(m => m.includes('//www.youtube.com/')));
const yt = realm(`
  var sent = [], listeners = {}, mediaListeners = {};
  var location = { hostname: 'www.youtube.com', origin: 'https://www.youtube.com', href: 'https://www.youtube.com/watch?v=X', search: '?v=X' };
  var window = globalThis;
  window.addEventListener = (type, f) => { listeners[type] = f; };
  window.postMessage = () => {};
  class URLSearchParams {
    constructor(s) { this.m = {}; for (const kv of String(s).replace(/^\\?/, '').split('&')) { const [k, v = ''] = kv.split('='); if (k) this.m[k] = v; } }
    get(k) { return k in this.m ? this.m[k] : null; }
  }
  var main = { currentTime: 0, paused: true, ended: false, isConnected: true, closest: (sel) => sel === '#movie_player' ? {} : null };
  var preview = { currentTime: 7, paused: true, ended: false, isConnected: true, closest: () => null };
  var document = { addEventListener(type, f) { mediaListeners[type] = f; },
                   querySelector(sel) { return sel.includes('#movie_player') ? main : null; }, getElementById() { return null; },
                   documentElement: { classList: { add() {}, remove() {} } } };
  var chrome = { runtime: { sendMessage: (m) => { sent.push(m); return Promise.resolve(null); } } };
  function fromPage(data) { listeners.message({ source: window, origin: location.origin, data: { __aiquotaLyrics: 1, ...data } }); }
  function media(type, target) { mediaListeners[type]({ target }); }
  function last() { return sent[sent.length - 1]; }
`);
loads(yt, isolated.js, 'YouTube 扩展环境脚本（带假播放器）');
const track = JSON.stringify({ events: [
  { tStartMs: 0, dDurationMs: 3000, segs: [{ utf8: 'X line one' }] },
  { tStartMs: 3000, dDurationMs: 3000, segs: [{ utf8: 'X line two' }] },
  { tStartMs: 6000, dDurationMs: 3000, segs: [{ utf8: 'X line three' }] },
] });
yt.evalScript(`
  fromPage({ what: 'video', v: 'X', title: 'Video X', author: '', hasTracks: false });
  fromPage({ what: 'track', v: 'X', text: ${JSON.stringify(track)} });
  main.paused = false; main.currentTime = 1; media('play', main);
`);
check(yt.evalScript(`last()?.playing === true && last()?.line === 'X line one' && last()?.title === 'Video X'`) === true, 'YouTube 主播放器在放时报当前一句');
yt.evalScript(`main.paused = true; media('pause', main); var before = sent.length;
               preview.paused = false; media('play', preview); preview.currentTime = 7.2; media('timeupdate', preview);`);
check(yt.evalScript(`sent.slice(before).every(m => !m.playing)`) === true, '悬停预览、Shorts 在放时不拿上一个视频的字幕报在放');
yt.evalScript(`location.search = '?v=Y'; location.href = 'https://www.youtube.com/watch?v=Y'; var beforeNext = sent.length;
               main.paused = false; main.currentTime = 6.5; media('play', main);`);
check(yt.evalScript(`sent.length === beforeNext`) === true, '地址已经换成下一个视频、新字幕还没来时不拿旧字幕报');
yt.evalScript(`location.search = ''; location.href = 'https://www.youtube.com/'; main.currentTime = 3.5; media('timeupdate', main);`);
check(yt.evalScript(`last()?.playing === true && last()?.line === 'X line two'`) === true, '小窗播放（地址里没有 v）照常报');

print('PASS: ' + checks + ' checks (Chrome 扩展)');
