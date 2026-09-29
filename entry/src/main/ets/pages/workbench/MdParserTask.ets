import { taskpool } from '@kit.ArkTS';
import { parseMarkdownBlocks, type MdBlock } from 'utils';

/**
 * OUT-1：块级解析的 TaskPool 投递（批次16）。
 * parseBlocksConcurrent 为纯函数投递（无闭包捕获，引用导入函数为 API 11+ 能力）；
 * 预览器等不支持环境自动降级为同步解析——降级路径与设备路径产出一致（同一纯函数）。
 */
@Concurrent
function parseBlocksConcurrent(text: string): object {
  return parseMarkdownBlocks(text) as object;
}

export async function parseBlocks(text: string): Promise<MdBlock[]> {
  try {
    const task: taskpool.Task = new taskpool.Task(parseBlocksConcurrent, text);
    const result = await taskpool.execute(task) as MdBlock[];
    return result;
  } catch (error) {
    return parseMarkdownBlocks(text);
  }
}
