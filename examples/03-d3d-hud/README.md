# 示例 03 · D3D HUD（Font / Text / Texture）

使用 `jass.d3d` 绘制半透明贴图底板与每 0.1 秒刷新的 HUD 文本。0.5.0 起支持零重启进程内 D3D9 激活，常规 D3D9 模式下无需手动安装代理即可直接渲染。

## 构建与运行

```powershell
japi build examples\03-d3d-hud -o dist\03-d3d-hud.w3x
japi run   examples\03-d3d-hud
```
