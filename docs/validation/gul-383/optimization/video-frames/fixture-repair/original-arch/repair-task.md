当前仅同一PR638测试夹具窄修与交回，不新建PR、不扩展下一片，约30min保存交回。开发仅Dev/GPT-SOL。保留f9c7aed270e7d4a399d487d5081345907933a2ad现有生产源码、已通过15个相关方法、coverage和MOV证据；不要重跑20方法/重建整批/为90%补测。用户门槛>=70%，应用/文件helper/媒体runtime变更可执行行分列。

Arch已核对2417源码/工具/资源冻结指纹（审查树和Dev原树均匹配）、1117生产对象、最终instrumented测试二进制、4工具和4原始profile，重算coverage应用62/62、文件helper73/74、runtime0/0N/A，与提交一致。产品采样/去重/进度/迁移/直接调用方审查暂无已确认生产缺陷。但独立复用最终二进制原生SemanticVideoFrameTests在首方法movie夹具生成阶段两次SIGABRT：AVAssetWriterInputPixelBufferAdaptor appendPixelBuffer时readyForMoreMediaData==NO；movie仅100*5ms轮询，结束后无条件append。两次11.70485s/2.40457s，0构建；测试组第一次方法即中止，未验证产品解码。这不是已证明生产路径失败，不扩大产品重构。

最小修复使真实MOV夹具可可靠获得：优先直接复用本PR已提交/冻结的short-scene.mov、static-scene.mov、longer-audio.mov，或按现有风格正确等待writer并在有界超时后通过Testing可读失败返回，不能继续向未就绪writer追加。不要盲目放大睡眠、掩盖失败、仅重试至绿。保留真实短画面/尾帧、近似去重、实际时间、真实IPC取消和文档抢占恢复、迁移/回滚断言。若复用固定MOV，明确来源/hash，不能改成模拟解码。只跑这次中断的最小SemanticVideoFrameTests（5方法，包含两种恢复参数），不重复其他已通过15方法。生产未变则复用既有覆盖率和生产对象指纹，新增测试范围按需有效coverage执行一次；重建只更新必要测试对象，不为报表全量重建。

提交修复到同一PR638，冻结新最终head和源码/工具/fixture/profile/binary指纹，保留原失败及新最小复验完整时间/构建/重试日志。原生产coverage>=70%无需提高，helper未覆盖关闭括号无须补测。约30min到点停止扩展保存交回，明确仍未完成GUL405，不能自行合并或启动406。

剩余保持：嵌入视频音轨重叠/静音恢复、音视频时间打开与能力回退、分项partial/失败定点重试、Range/ETag/checksum下载恢复、新增内容真实模型/原生输入短验。GUL405及父GUL383继续in_progress。
