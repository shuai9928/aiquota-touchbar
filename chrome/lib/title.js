// Bilibili music-video title -> ranked [{title, artist, why}] candidates. Pure JS, no deps.
const NOISE = [
  'official music video', 'official video', 'official mv', 'official audio', 'music video', 'lyric video', 'lyrics video',
  'full version', 'full ver', 'tv size', 'tv ver', 'from the first take', 'the first take',
  '动态歌词', '歌词版', '中日字幕', '中英字幕', '中日双语', '双语字幕', '日语中字', '中字', '字幕', '歌词',
  '无损音质', '无损', '高音质', '高品质', '音质', 'hi-res', 'hires', 'flac', '24bit', '96khz', '192khz', '杜比', 'dolby', 'atmos',
  '4k60', '4k', '8k', '1080p', '60帧', '60fps', '修复版', '修复', '重制版', 'remastered', 'remaster',
  '官方mv', '官方版', '官方', 'mv', 'pv', 'm/v',
  '伴奏', '纯音乐', 'instrumental', 'inst', 'karaoke', 'off vocal',
  '完整版', '完整', '单曲循环', '循环', '纯享版', '纯享', '现场版', '现场', 'live',
  '翻唱', '翻自', 'covered by', 'cover', '女声版', '男声版', '女声', '男声', '钢琴版', '吉他版', '弹唱',
  '降调版', '降调', '升调', '加速版', '降速版', '降速', 'slowed', 'sped up', 'reverb', 'nightcore',
  '首发', '新歌', '热门', '抖音', '治愈', '神曲',
];
const SPEED_RE = /\b[01]\.\d{1,2}\s*(?:x|倍速?)?(?=\D|$)/gi;           // 0.8x / 1.25倍
const ORIGINAL_ARTIST_RE = /(?:原唱|cover|翻自|翻唱自)\s*[:：]?\s*([^\s,，/|()（）\[\]【】《》「」『』]+)/i;
const HAS_WORD = /[\p{L}]/u;
const CJK = '\\u3040-\\u30ff\\u3400-\\u9fff\\uac00-\\ud7af';

function norm(s) {
  return String(s)
    .normalize('NFKC')                                   // 𝐇𝐢-𝐑𝐞𝐬 -> Hi-Res, full-width -> ASCII, ｜ -> |
    .replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#39;/g, "'")
    .replace(/<[^>]+>/g, '')                             // <em class="keyword"> in search results
    .replace(/[\u2010-\u2015\u2212\uFE58\uFE63]+/g, '-') // all dashes -> '-'
    .replace(/[\u2018\u2019\u201A\u201B]/g, "'")
    // "晴  天" / "操 场 翻 唱": single CJK chars separated by spaces -> join
    .replace(new RegExp(`(?<![${CJK}])(?:[${CJK}]\\s+){1,}[${CJK}](?![${CJK}])`, 'gu'),
             m => /^(?:[^\s]\s+)+[^\s]$/u.test(m) && m.split(/\s+/).every(x => [...x].length === 1) ? m.replace(/\s+/g, '') : m)
    .replace(/\s+/g, ' ')
    .trim();
}

function stripNoise(s) {
  let out = ' ' + s + ' ';
  for (const w of NOISE) {
    const esc = w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const re = /^[\x00-\x7f]+$/.test(w)
      ? new RegExp(`(?<![a-z0-9])${esc}(?![a-z0-9])`, 'gi')
      : new RegExp(esc, 'g');
    out = out.replace(re, ' ');
  }
  return out.replace(SPEED_RE, ' ');
}

// keep letters, digits, '.', '&', "'" (artist names like G.E.M., Mrs. GREEN APPLE); drop separators
const clean = s => stripNoise(s || '').replace(/[\s\-_|~·•:：,，。!！?？#+"“”]+/g, ' ').trim();
const lastToken = s => (clean(s).split(' ').filter(Boolean).pop() || '');

function artistVariants(a) {
  // "陈奕迅 Eason Chan" -> ["陈奕迅 Eason Chan", "陈奕迅", "Eason Chan"]
  const v = new Set([a]);
  const cjk = (a.match(new RegExp(`[${CJK}]+`, 'gu')) || []).join(' ').trim();
  const lat = a.replace(new RegExp(`[${CJK}]+`, 'gu'), ' ').replace(/\s+/g, ' ').trim();
  if (cjk && lat && /[a-z]/i.test(lat)) { v.add(cjk); v.add(lat); }
  return [...v].filter(Boolean);
}

function parseBiliTitle(rawTitle, opts = {}) {
  const tags = (opts.tags || []).map(t => norm(t).toLowerCase());
  const t0 = norm(rawTitle);
  const out = [];
  const push = (title, artist, why) => {
    title = clean(title); artist = clean(artist);
    if (!title || !HAS_WORD.test(title)) return;
    if (title.length > 40) return;                        // sentences are not song names
    if (!out.some(c => c.title === title && c.artist === artist)) out.push({ title, artist, why });
  };

  const orig = t0.match(ORIGINAL_ARTIST_RE);
  const origArtist = orig && HAS_WORD.test(clean(orig[1])) ? orig[1] : '';

  // pull out 【】 [] 〔〕 () （） groups; keep their text as fallback
  const groups = [];
  let rest = t0.replace(/【([^】]*)】|\[([^\]]*)\]|〔([^〕]*)〕|（([^）]*)）|\(([^)]*)\)/g,
    (m, a, b, c, d, e) => { groups.push(a || b || c || d || e || ''); return ' | '; });

  // 1) quoted song: 《》「」『』“”  (strongest signal)
  const q = rest.match(/《([^》]+)》|「([^」]+)」|『([^』]+)』|“([^”]+)”/) ||
            t0.match(/《([^》]+)》|「([^」]+)」|『([^』]+)』/);
  if (q) {
    const song = q[1] || q[2] || q[3] || q[4];
    const i = rest.indexOf(q[0]);
    const before = i >= 0 ? rest.slice(0, i) : '';
    const after = i >= 0 ? rest.slice(i + q[0].length) : '';
    const artB = lastToken(before.split(/[|/]| - /).pop());            // "邓紫棋《光年之外》", "翻唱周杰伦《晴天》"
    const artA = clean((after.match(/^\s*[-/|]\s*([^-|/]+)/) || [])[1]); // "《晴天》- 周杰伦 - ..."
    if (origArtist) push(song, origArtist, 'quoted+original');
    if (artB) push(song, artB, 'quoted+before');
    if (artA) push(song, artA, 'quoted+after');
    push(song, '', 'quoted');
    rest = rest.replace(q[0], ' | ');
  }

  // 2) "A - B" / "A / B" / "A｜B": order is ambiguous in Chinese uploads, emit both
  let base = clean(rest) ? rest : groups.join(' | ');
  if (!HAS_WORD.test(clean(base))) base = groups.join(' | ');
  let parts = base.split(/\s+[-/]\s+|\s*\|\s*/).map(clean).filter(p => HAS_WORD.test(p));
  if (parts.length < 2) {
    const g = groups.map(clean).find(x => /\S-\S| - /.test(x)) ? groups.find(x => /-/.test(x)) : null;
    parts = (g || base).split(/\s*-\s*|\s*\/\s*/).map(clean).filter(p => HAS_WORD.test(p));
  }
  if (parts.length >= 2) {
    push(parts[1], parts[0], 'dash:artist-title');
    push(parts[0], parts[1], 'dash:title-artist');
  }
  for (const p of parts) push(p, origArtist, 'segment');

  // 3) bilibili tags (videoData tags, e.g. ["晴天","周杰伦","翻唱"]) boost candidates whose fields are tags
  const tagSet = new Set(tags);
  for (const c of out) c.score = (c.why.startsWith('quoted') ? 2 : 0) + (c.artist ? 1 : 0)
    + 2 * [c.title, c.artist].filter(x => x && tagSet.has(x.toLowerCase())).length;
  out.sort((a, b) => b.score - a.score);
  return out.map(c => ({ ...c, artistVariants: c.artist ? artistVariants(c.artist) : [] }));
}

if (typeof module !== 'undefined') module.exports = { parseBiliTitle, norm, artistVariants };
