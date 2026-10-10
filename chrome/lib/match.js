// Score provider candidates {provider,id,title,artist,durationSec,synced} against a parsed query + video duration.
const VERSION_WORDS = /(live|现场|remix|dj|伴奏|inst|karaoke|off vocal|纯音乐|钢琴|piano|吉他|guitar|翻自|原唱|cover|翻唱|女声|男声|demo|加速|降调|0\.8|tv\s*(size|ver)|short|片段|oke)/i;
const key = s => String(s || '').normalize('NFKC').toLowerCase()
  .replace(/[\s\-_.,，。'"“”‘’!！?？:：·・/\\|()（）\[\]【】《》「」『』&]+/g, '');

function titleScore(q, c) {
  const a = key(q), b = key(c.replace(/\s*[(（\[【].*?[)）\]】]\s*/g, ''));   // ignore "(Live)" etc. for equality
  if (!a || !b) return 0;
  if (a === b) return 1;
  if (b.includes(a) || a.includes(b)) return 0.7;
  return 0;
}
function artistScore(variants, cArtist) {
  if (!variants.length) return 0.5;                                  // unknown artist: neutral
  const b = key(cArtist);
  return variants.some(v => { const a = key(v); return a && (b.includes(a) || a.includes(b)); }) ? 1 : 0;
}
// |Δ| in seconds between the video (current page) and the recording the LRC was timed against
function durationScore(videoSec, candSec, ratios = []) {
  if (!candSec || candSec < 30) return { s: 0, ratio: 1 };           // LRCLIB has junk durations (e.g. 4.0)
  const d = Math.abs(videoSec - candSec);
  if (d <= 2) return { s: 1, ratio: 1 };
  if (d <= 5) return { s: 0.7, ratio: 1 };
  if (d <= 10) return { s: 0.3, ratio: 1 };                            // usable only with manual nudge
  const r = candSec / videoSec;                                       // 0.8x "降调/slowed" re-uploads
  for (const k of ratios) if (Math.abs(r - k) < 0.01) return { s: 0.3, ratio: r }; // only if title says 0.8x/降调/加速
  return { s: 0, ratio: 1 };                                          // reject: LRC timing won't fit
}
function scoreCandidate(q, c, videoSec, ratios = [], queryIsVersion = false) {
  const t = titleScore(q.title, c.title);
  const ar = artistScore(q.artistVariants || [], c.artist);
  const dur = durationScore(videoSec, c.durationSec, ratios);
  let s = 3 * t + 2 * ar + 4 * dur.s + (c.synced ? 1 : -10);
  if (!queryIsVersion && VERSION_WORDS.test(c.title) && !VERSION_WORDS.test(q.title)) s -= 1.5; // live/伴奏/翻自 versions
  const ok = c.synced && t > 0 && (dur.s >= 0.7 || dur.ratio !== 1) && (ar > 0 || t === 1); // 0.3 band => 'maybe', needs manual nudge
  return { ...c, score: +s.toFixed(2), ok, t, ar, dur: dur.s, timeScale: dur.ratio };
}
// speed hints from the raw video title: "0.8x"/"降调"/"slowed" => 0.8 ; "1.25x"/"加速"/"sped up" => 1.25
const speedRatios = raw => {
  const r = [], m = String(raw).match(/\b([01]\.\d{1,2})\s*(?:x|倍)/i);
  if (m) r.push(+m[1]);
  if (/降调|降速|slowed/i.test(raw)) r.push(0.8, 0.85, 0.9);
  if (/加速|升调|sped\s*up|nightcore/i.test(raw)) r.push(1.1, 1.2, 1.25);
  return r;
};
function pickBest(q, cands, videoSec, rawTitle = '') {
  const ratios = speedRatios(rawTitle);
  const scored = cands.map(c => scoreCandidate(q, c, videoSec, ratios)).sort((a, b) => b.score - a.score);
  return { best: scored.find(c => c.ok) || null, scored };
}
if (typeof module !== 'undefined') module.exports = { pickBest, scoreCandidate, key };
