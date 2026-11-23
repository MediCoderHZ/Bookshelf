# Bookshelf 本机协作约定

- 用户要求日常开发、体验只使用一个应用入口，不再打开多个验证版本。
- 固定安装路径：`~/Applications/Bookshelf.app`；固定 Bundle Identifier：`io.github.medicoderhz.bookshelf`；中英文界面均使用固定名称“Bookshelf”。
- 更新本机应用使用 `bash scripts/install-local.sh`，或用 `--app` 安装已经编译验证的 Release 产物。该脚本不启动应用；通过正常应用操作退出当前实例、安装后再打开这个固定入口。
- 不再为普通界面验证创建新的验证 Bundle Identifier、另一个书库或新的运行副本。自动测试使用现有测试工具与临时数据；不要在用户正式书库中自动添加验证样本。
- 不删除或重新初始化现有书库。迁移或合并数据前先备份，在副本上校验完整性与关联关系，成功后再交付；备份与个人数据放在 Git 忽略的 `work/`，不得提交或上传。
- 本机临时签名与正式 Developer ID 分发分开；本机安装不代表已经签名公证或发布。
