// YouTube 字幕（timedtext 的 json3 格式）→ [{start, end, text}]（毫秒）。
// 自动生成的字幕（asr）是逐词、互相重叠的滚动显示，要先拆成词再按标点、停顿和长度重新断句。
(() => {
  const AQ = (globalThis.AQ = globalThis.AQ || {});
  const CJK = /[぀-ヿ㐀-鿿가-힯＀-￯]/;

  function json3ToCues(j, { maxChars = 60, maxGapMs = 1200 } = {}) {
    const evs = (j.events || []).filter(e => e.segs && !e.aAppend);   // 去掉窗口定义和换行追加事件
    const isAsr = evs.some(e => e.segs.some(s => 'tOffsetMs' in s || 'acAsrConf' in s));
    const out = [];
    if (!isAsr) {
      for (const e of evs) {
        const text = e.segs.map(s => s.utf8 || '').join('').replace(/\s*\n\s*/g, ' ').trim();
        if (text) out.push({ start: e.tStartMs, end: e.tStartMs + (e.dDurationMs || 5000), text });
      }
    } else {
      const words = [];
      for (const e of evs) e.segs.forEach((s, i) => {
        const w = (s.utf8 || '').replace(/\n/g, ' ');
        if (w.trim()) words.push({ t: e.tStartMs + (s.tOffsetMs || 0), w, first: i === 0 });
      });
      words.sort((a, b) => a.t - b.t);
      let cur = null;
      const flush = () => { if (cur) { cur.text = cur.text.trim(); if (cur.text) out.push(cur); cur = null; } };
      for (const { t, w, first } of words) {
        if (/^\s*\[.*\]\s*$/.test(w)) { flush(); out.push({ start: t, last: t, text: w.trim() }); continue; }   // [Music]
        if (cur && (t - cur.last > maxGapMs || (cur.text + w).length > maxChars)) flush();
        if (!cur) cur = { start: t, last: t, text: '' };
        const prev = cur.text.slice(-1);
        const sep = first && prev && !/\s/.test(prev) && !/^\s/.test(w) && !CJK.test(prev) && !CJK.test(w[0]) ? ' ' : '';
        cur.text += sep + w;
        cur.last = t;
        if (/[.?!。？！]\s*$/.test(w)) flush();
      }
      flush();
    }
    out.sort((a, b) => a.start - b.start);
    out.forEach((l, i) => {
      const own = l.end ?? (l.last + 2000);
      const next = out[i + 1];
      l.end = next ? Math.min(own, next.start) : own;
      delete l.last;
    });
    return out;
  }

  AQ.json3ToCues = json3ToCues;
})();
