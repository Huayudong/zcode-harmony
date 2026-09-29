/**
 * MarkdownBlocks —— OUT-1 增量渲染的块级解析结构（纯函数，node/设备双端可运行）。
 *
 * 设计要点（对应 PRD 6.2 渲染管线 M1 部分）：
 * - 块级切分：paragraph / heading / list / quote / code；行内仅一层 **bold** 与 `code`。
 * - **增量友好**：流式追加只影响尾部块，前缀块的形状逐字段稳定——渲染层用
 *   mdBlockKey() 作为 ForEach key（内容不变 → key 不变 → ArkUS 复用组件不重建），
 *   这是「增量解析结构」在整表重绘框架下的落点。
 * - **TaskPool 预留**：parse 为无闭包捕获的纯函数，可直接投递 @ohos.taskpool.Task；
 *   切换调用点属真机性能批（需要 Profiler 基线对比）。
 * - 已知边界（刻意不做）：表格/嵌套列表/多级行内嵌套/围栏 ~~~；正文仍以纯文本语义兜底。
 */

export type MdBlockKind = 'paragraph' | 'heading' | 'code' | 'list' | 'quote';

/** 行内片段（M1：粗体与行内代码各一层，不嵌套）。 */
export interface MdSpan {
  text: string;
  bold: boolean;
  code: boolean;
}

/** 块级渲染单元。 */
export interface MdBlock {
  kind: MdBlockKind;
  /** heading 层级 1-6；非 heading 为 0。 */
  level: number;
  /** 代码块语言（空串 = 未标注）。 */
  lang: string;
  /** 代码块是否闭合（流式中未闭合 = false，渲染按暂态处理防闪烁）。 */
  closed: boolean;
  /** 列表是否有序。 */
  ordered: boolean;
  /** 段落/引用为一行 span；列表为每项一行 span。 */
  spans: MdSpan[][];
  /** 列表项数（非列表为 0）。 */
  itemCount: number;
}

const RE_HEADING = /^#{1,6}\s+/;
const RE_HEADING_CAPTURE = /^(#{1,6})\s+(.*)$/;
const RE_ULIST = /^\s*[-*+]\s+(.*)$/;
const RE_OLIST = /^\s*\d+[.)]\s+(.*)$/;
const RE_INLINE = /(`([^`]+)`)|(\*\*([^*]+)\*\*)/;

/** 行内片段解析：`code` 与 **bold**，其余为普通文本；空输入返回单个空 span。 */
export function parseInlineSpans(text: string): MdSpan[] {
  const spans: MdSpan[] = [];
  let rest = text;
  while (rest.length > 0) {
    const match = RE_INLINE.exec(rest);
    if (match === null) {
      spans.push({ text: rest, bold: false, code: false });
      break;
    }
    if (match.index > 0) {
      spans.push({ text: rest.substring(0, match.index), bold: false, code: false });
    }
    if (match[2] !== undefined) {
      spans.push({ text: match[2], bold: false, code: true });
    } else {
      spans.push({ text: match[4], bold: true, code: false });
    }
    rest = rest.substring(match.index + match[0].length);
  }
  if (spans.length === 0) {
    spans.push({ text: '', bold: false, code: false });
  }
  return spans;
}

function isStructuralStart(line: string): boolean {
  return line.startsWith('```') || RE_HEADING.test(line) || RE_ULIST.test(line)
    || RE_OLIST.test(line) || line.startsWith('>');
}

/** 块级解析：流式安全的稳定前缀语义（追加文本只改变尾部块）。 */
export function parseMarkdownBlocks(text: string): MdBlock[] {
  const blocks: MdBlock[] = [];
  const lines = text.split('\n');
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (line.startsWith('```')) {
      const lang = line.substring(3).trim();
      const body: string[] = [];
      i += 1;
      let closed = false;
      while (i < lines.length) {
        if (lines[i].startsWith('```')) {
          closed = true;
          i += 1;
          break;
        }
        body.push(lines[i]);
        i += 1;
      }
      blocks.push({
        kind: 'code', level: 0, lang: lang, closed: closed, ordered: false,
        spans: [[{ text: body.join('\n'), bold: false, code: true }]],
        itemCount: 0,
      });
      continue;
    }
    if (line.trim().length === 0) {
      i += 1;
      continue;
    }
    const heading = RE_HEADING_CAPTURE.exec(line);
    if (heading !== null) {
      blocks.push({
        kind: 'heading', level: heading[1].length, lang: '', closed: true, ordered: false,
        spans: [parseInlineSpans(heading[2])], itemCount: 0,
      });
      i += 1;
      continue;
    }
    if (RE_ULIST.test(line) || RE_OLIST.test(line)) {
      const ordered = RE_OLIST.test(line);
      const itemRe = ordered ? RE_OLIST : RE_ULIST;
      const itemSpans: MdSpan[][] = [];
      while (i < lines.length) {
        const item = itemRe.exec(lines[i]);
        if (item === null) {
          break;
        }
        itemSpans.push(parseInlineSpans(item[1]));
        i += 1;
      }
      blocks.push({
        kind: 'list', level: 0, lang: '', closed: true, ordered: ordered,
        spans: itemSpans, itemCount: itemSpans.length,
      });
      continue;
    }
    if (line.startsWith('>')) {
      const quoteLines: string[] = [];
      while (i < lines.length && lines[i].startsWith('>')) {
        quoteLines.push(lines[i].replace(/^>\s?/, ''));
        i += 1;
      }
      blocks.push({
        kind: 'quote', level: 0, lang: '', closed: true, ordered: false,
        spans: [parseInlineSpans(quoteLines.join('\n'))], itemCount: 0,
      });
      continue;
    }
    const paragraph: string[] = [];
    while (i < lines.length && lines[i].trim().length > 0 && !isStructuralStart(lines[i])) {
      paragraph.push(lines[i]);
      i += 1;
    }
    blocks.push({
      kind: 'paragraph', level: 0, lang: '', closed: true, ordered: false,
      spans: [parseInlineSpans(paragraph.join('\n'))], itemCount: 0,
    });
  }
  return blocks;
}

/** 渲染复用 key：块形状与内容长度稳定 → key 稳定（ArkUS ForEach 按 key 复用）。 */
export function mdBlockKey(block: MdBlock): string {
  let contentLength = 0;
  for (const line of block.spans) {
    for (const span of line) {
      contentLength += span.text.length;
    }
  }
  return `${block.kind}:${block.level}:${block.lang}:${block.closed ? 1 : 0}:${block.ordered ? 1 : 0}:${block.itemCount}:${contentLength}`;
}
