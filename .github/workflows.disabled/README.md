# 已禁用的上游工作流（仅供参考）

本目录中的 GitHub Actions 工作流文件来自上游工程流程，通常依赖：

- `namespace-profile-*` 自托管 runner；
- `ghostty-org/ghostty` 仓库的发布基础设施与密钥（例如 Cachix、R2、签名等）；
- 上游的发布与制品分发管线。

对于本仓库而言，这些工作流默认不可用且会带来误触发/噪声，因此已从 `.github/workflows/` 移出并集中放到本目录，仅用于历史参考。

本仓库当前的 CI 入口以 `.github/workflows/project-ci.yml` 为准。

