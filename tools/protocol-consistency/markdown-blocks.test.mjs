// MarkdownBlocks 增量解析门禁（批次15 / OUT-1 离线部分）。
// 关键断言：流式追加只改变尾部块——前缀块逐字段稳定（ForEach key 复用的前提）。
// 运行：随 npm test（tsx 直读 utils 纯 TS）。
import assert from 'node:assert/strict';
import { test } from 'node:test';

const MD = '../../commons/utils/src/main/ets/markdown/MarkdownBlocks.js';
const md = await import(MD);

test('块级解析：标题/列表/引用/代码/段落与行内样式', () => {
  const text = [
    '# 标题一',
    '',
    '普通段落，含 **加粗** 与 `行内代码`。',
    '',
    '- 项目甲',
    '- 项目乙 **粗**',
    '',
    '1. 第一',
    '2. 第二',
    '',
    '> 引用一行',
    '',
    '```ts',
    'const x = 1;',
    '```',
  ].join('\n');
  const blocks = md.parseMarkdownBlocks(text);
  assert.deepEqual(blocks.map((b) => b.kind), ['heading', 'paragraph', 'list', 'list', 'quote', 'code']);
  assert.equal(blocks[0].level, 1);
  // 行内：['普通段落，含 ', bold'加粗', ' 与 ', code'行内代码', '。']
  assert.equal(blocks[1].spans[0].length, 5);
  assert.equal(blocks[1].spans[0][1].bold, true);
  assert.equal(blocks[1].spans[0][1].text, '加粗');
  assert.equal(blocks[1].spans[0][3].code, true);
  assert.equal(blocks[1].spans[0][3].text, '行内代码');
  // 列表
  assert.equal(blocks[2].itemCount, 2);
  assert.equal(blocks[2].ordered, false);
  assert.equal(blocks[2].spans[1][0].text.length, 4); // 项目乙+空格
  assert.equal(blocks[3].ordered, true);
  // 代码块
  assert.equal(blocks[5].lang, 'ts');
  assert.equal(blocks[5].closed, true);
  assert.equal(blocks[5].spans[0][0].text, 'const x = 1;');
});

test('增量语义：尾部追加不改前缀块（key 稳定 → 渲染复用）', () => {
  const before = '第一段正文\n\n```python\nprint(1)';
  const after = before + '\nprint(2)\n```\n\n收尾段落';

  const b1 = md.parseMarkdownBlocks(before);
  // 未闭合围栏：暂态代码块（closed=false）
  assert.equal(b1.length, 2);
  assert.equal(b1[0].kind, 'paragraph');
  assert.equal(b1[1].kind, 'code');
  assert.equal(b1[1].closed, false);

  const b2 = md.parseMarkdownBlocks(after);
  assert.equal(b2.length, 3);
  // 前缀块逐字段稳定
  assert.deepEqual(b2[0], b1[0]);
  assert.equal(b2[1].closed, true);
  assert.equal(b2[1].lang, 'python');
  assert.equal(b2[2].kind, 'paragraph');

  // key：前缀块稳定；尾部块变化
  assert.equal(md.mdBlockKey(b2[0]), md.mdBlockKey(b1[0]));
  assert.notEqual(md.mdBlockKey(b2[1]), md.mdBlockKey(b1[1]));
});

test('防御：空文本、无行内标记、未闭合围栏', () => {
  assert.equal(md.parseMarkdownBlocks('').length, 0);
  const plain = md.parseMarkdownBlocks('只有一段');
  assert.equal(plain[0].kind, 'paragraph');
  assert.equal(plain[0].spans[0].length, 1);
  assert.equal(plain[0].spans[0][0].bold, false);

  const bare = md.parseMarkdownBlocks('```\nplain');
  assert.equal(bare.length, 1);
  assert.equal(bare[0].kind, 'code');
  assert.equal(bare[0].lang, '');
  assert.equal(bare[0].closed, false);
  assert.equal(bare[0].spans[0][0].text, 'plain');

  assert.deepEqual(md.parseInlineSpans(''), [{ text: '', bold: false, code: false }]);
});
