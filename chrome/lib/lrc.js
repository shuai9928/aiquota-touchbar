// LRC 歌词解析，和「当前是哪一句」的查找。内容脚本和后台 service worker 共用，挂在 globalThis.AQ 上。
// 支持：BOM/CRLF、[ar:] 这类元数据、[offset:]、一行多个时间、[mm:ss]/[mm:ss.x|xx|xxx]/[mm:ss:xx]、
// 逐字时间 <mm:ss.xx>、网易云开头的 JSON 署名行、空行（表示间奏，清空显示）。
(() => {
  const AQ = (globalThis.AQ = globalThis.AQ || {});
  const TS = /\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]/g;
  const WORD_TS = /<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>/g;
  const META = /^\[([a-zA-Z#]+):(.*)\]\s*$/;
  // 作词作曲这类署名行不上触控栏
  const CREDIT = /^(作词|作曲|编曲|制作人|制作|监制|混音|录音|母带|和声|吉他|贝斯|鼓|弦乐|钢琴|出品|发行|企划|OP|SP|词|曲|lyrics|composer|arranger|producer)\s*[:：]/i;

  const toMs = (m, s, f) => (+m) * 60000 + (+s) * 1000 + (f ? Math.round(+(f + '00').slice(0, 3)) : 0);

  function parseLRC(text) {
    const meta = {};
    const raw = [];
    for (let line of String(text).replace(/^﻿/, '').split(/\r\n|\r|\n/)) {
      line = line.trim();
      if (!line) continue;
      if (line[0] === '{') {                                   // 网易云署名行 {"t":ms,"c":[{"tx":..}]}
        try { const o = JSON.parse(line); raw.push({ t: o.t, text: (o.c || []).map(c => c.tx).join('').trim(), credit: true }); } catch {}
        continue;
      }
      TS.lastIndex = 0;
      const stamps = [];
      let m, end = 0;
      while ((m = TS.exec(line)) && m.index === end) { stamps.push(toMs(m[1], m[2], m[3])); end = TS.lastIndex; }
      if (!stamps.length) {
        const mm = line.match(META);
        if (mm) meta[mm[1].toLowerCase()] = mm[2].trim();
        continue;
      }
      const body = line.slice(end).replace(new RegExp(WORD_TS.source, 'g'), '').replace(/^\s*[MFD]:\s*/, '').trim();
      for (const t of stamps) raw.push({ t, text: body });
    }
    const offsetMs = parseInt(meta.offset || '0', 10) || 0;     // [offset:+500] 表示提前 500 毫秒显示
    const lines = raw.map(l => ({ ...l, t: l.t - offsetMs })).sort((a, b) => a.t - b.t);
    return { meta, lines };
  }

  /// LRC → [{start, end, text}]（毫秒，视频时间）。timeScale：歌词对应的录音时长 / 视频时长（0.8x 这类变速版才不是 1）
  function lrcToCues(text, timeScale = 1) {
    const lines = parseLRC(text).lines;
    const cues = lines.map(l => ({
      start: Math.max(0, l.t / timeScale),
      text: l.credit || CREDIT.test(l.text) ? '' : l.text,
    }));
    cues.forEach((c, i) => { c.end = i + 1 < cues.length ? cues[i + 1].start : c.start + 8000; });
    return cues;
  }

  /// 有几句是真正的歌词（去掉署名和空行）
  AQ.lyricLineCount = (cues) => cues.filter(c => c.text).length;

  /// 最后一句 start <= ms 的下标，还没开始时是 -1
  function cueIndex(cues, ms) {
    let lo = 0, hi = cues.length - 1, ans = -1;
    while (lo <= hi) { const mid = (lo + hi) >> 1; if (cues[mid].start <= ms) { ans = mid; lo = mid + 1; } else hi = mid - 1; }
    return ans;
  }

  Object.assign(AQ, { parseLRC, lrcToCues, cueIndex });
})();
