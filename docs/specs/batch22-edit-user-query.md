# 批次22 Spec：editUserQuery 原生「修改后重发」（OUT-7 收口）

范围：失败卡片「修改后重发」从本地回填（editLastInput，新发一条消息）升级为协议原生
editUserQuery——服务端替换原 userInput 行文本并切换 conversation 分支重跑；替代批次18
的简化实现，批次19 遗留项收口。

## 协议面

- 命令：`editUserQuery`（上游 commandPayloadSchemas 既有词表）：
  `{ target: {rowId, entityId}, newText, attachments?, workspaceMode?: 'preserve'|'rewind' }`。
- **双 CAS 名单**：同时在 COMMANDS_REQUIRING_BASE_REVISION（baseRevision 必带）与
  ROW_TARGETING_COMMANDS（baseLogEpoch 必带）——比 switch 命令更严（行定位防跨纪元错位）。
- 缺省 workspaceMode=preserve（仅切分支不动文件）；rewind 会先安全恢复该轮文件——
  App 侧 M1 不暴露该开关（防误触文件回滚），保持缺省。

## 实现面

- ConnectionEngine：CommandType +1。
- WorkbenchController.editUserQuery(sessionId, rowId, entityId, newText)：与 retryTurn 同款
  CAS 信封（revision + logEpoch；快照未就绪显式拒）。
- SessionDetail：
  - 失败卡片「修改后重发」→ startEditResend(failedRow)：向前找本会话中 rowId 小于失败行
    的最近一条非空 userInput 行，锚定（editTargetRowId/editTargetEntityId）并回填其文本；
    找不到目标行（异常形状）退回旧行为（普通回填新发）。
  - 编辑态横条：「正在编辑原消息，发送后将替换并重新执行」+ 取消（退出编辑态不清文本）。
  - send() 分流：编辑态发送走 editUserQuery（成功后清编辑态）；普通发送不变
    （sendText 无按次 mode，批次21 口径）。

## 门禁（33/33）

workbench-model.test.mjs 增 editUserQuery 信封组：双 CAS 齐备过 / 缺 baseRevision 拒 /
缺 baseLogEpoch 拒 / workspaceMode=rewind 过 / 缺 newText 拒。

## 真机批遗留

- 分支切换后的 UI 呈现（旧分支消息是否保留展示、快照 delta 形状）需联调实测；
- newText 空串由 UI 拦（协议 z.string() 不拒空），发送按钮已有非空守卫，无额外面。
