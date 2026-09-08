# Gaokun3 Linux Device Fixes

面向 Huawei MateBook E Go（`gaokun3`）的 Linux 用户态修复工具，涵盖 Adreno/Freedreno 图形加速和低刷新率触屏响应。项目不编译或安装内核，也不删除 GPU 库。

脚本最初在 Huawei MateBook E Go（`gaokun3`，Adreno 690/`FD690`）上验证，也适用于内核已经提供 MSM/Freedreno 支持的类似设备。

## 它解决什么问题

本仓库收录两个互不依赖的修复：

- GPU 修复移除错误的 Mesa/Zink/GBM/Vulkan 全局环境覆盖，避免硬件已正常工作却回退到 `llvmpipe`。
- 触屏修复调整 Himax HX83121A 的帧级防抖和丢帧容忍度，避免低刷新率下快速点击漏报或拖动中断。

两个脚本都会先检测目标硬件，只修改各自明确的运行时配置，并提供备份和回滚路径。

某些设备会在 `/etc/environment.d/` 或 `/etc/profile.d/` 中设置以下变量，强制 Mesa 使用不匹配的 Zink、GBM 或 Vulkan 后端：

```text
MESA_LOADER_DRIVER_OVERRIDE=zink
GBM_BACKENDS_PATH=/usr/local/lib/aarch64-linux-gnu/adreno/gbm
VK_DRIVER_FILES=freedreno_icd.json
```

当 Zink 的 Vulkan 初始化失败时，OpenGL 可能回退到软件渲染：

```text
OpenGL renderer string: llvmpipe (LLVM ...)
```

如果内核已经绑定 `adreno`/`msm` 驱动，移除这些强制覆盖即可让 Mesa 使用发行版提供的 Freedreno 驱动。成功后通常能看到 `freedreno`、`FD690` 或其他 Adreno 硬件标识。

## 快速开始

### GPU 用户态修复

先诊断（无需 root）：

```bash
./scripts/fix-gpu-userspace.sh --check
```

确认输出显示 Adreno/Freedreno 且问题来自环境覆盖后再修复：

```bash
sudo ./scripts/fix-gpu-userspace.sh --fix
```

`--fix` 会把匹配的配置备份到 `/var/backups/gpu-driver-fix/<timestamp>/`，写入 `manifest`，再将原文件改名为 `.disabled.<timestamp>`。它不会安装/卸载驱动、改内核或 GRUB、删除库或自动重启。已有桌面进程需注销并重新登录。

验证默认桌面渲染器：

```bash
env | grep -E '^(MESA|LIBGL|EGL|GBM|DRI|VK_|GALLIUM)' || echo 'no graphics overrides'
glxinfo -B | grep -E 'OpenGL vendor|OpenGL renderer'
eglinfo -B | grep -E 'OpenGL .*renderer|EGL vendor|MESA: error|libEGL warning'
```

回滚时使用 `--fix` 输出的目录：

```bash
sudo ./scripts/fix-gpu-userspace.sh --rollback \
  /var/backups/gpu-driver-fix/20260908T190000+0800
```

回滚不会覆盖用户后来新建的同名文件；遇到冲突会报告错误。回滚后同样需要重新登录。

### 低刷新率触屏修复

先诊断（无需 root）：

```bash
./scripts/fix-touch-low-fps.sh --check
```

确认找到 Himax HX83121A 调参节点后再应用：

```bash
sudo ./scripts/fix-touch-low-fps.sh --fix
```

脚本会保存原始 sysfs 值、立即应用平衡配置，并安装可回滚的 systemd 持久化服务。完整说明见 [TOUCH_LOW_FPS_FIX.md](TOUCH_LOW_FPS_FIX.md)。

## 日志与配置

默认日志为 `~/gaokun-kernel-build/build.log`。GPU 脚本使用 `GPU_FIX_LOG` 和 `GPU_FIX_BACKUP_ROOT`，触屏脚本使用 `TOUCH_FIX_LOG` 和 `TOUCH_FIX_BACKUP_ROOT`；两者默认共享 `/var/backups/gpu-driver-fix/`：

```bash
GPU_FIX_LOG=/tmp/gpu-driver-fix.log ./scripts/fix-gpu-userspace.sh --check
sudo GPU_FIX_BACKUP_ROOT=/var/backups/my-gpu-fix ./scripts/fix-gpu-userspace.sh --fix
sudo TOUCH_FIX_LOG=/tmp/touch-fix.log ./scripts/fix-touch-low-fps.sh --fix
```

## 适用范围与限制

GPU 脚本只处理“内核已支持 GPU，但用户态被错误环境变量覆盖”的情况；触屏脚本只处理已暴露 Himax HX83121A 算法 sysfs 节点的设备。脚本无法确认目标硬件或发现内核初始化失败时，会拒绝修改。此时收集以下信息，交给设备内核适配项目或 Linux/Mesa 上游：

```bash
uname -a
cat /proc/cmdline
readlink -f /sys/bus/platform/devices/3d00000.gpu/driver
journalctl -b -k | grep -iE 'msm|adreno|a6xx|gmu|firmware|drm'
ls -l /dev/dri
```

不要因为 ARM Qualcomm 设备上不存在 `nvidia-smi` 就安装 NVIDIA 驱动。

## 参与上游项目

若问题只在 `gaokun3` 设备的内核适配上出现，请在 [right-0903/linux-gaokun](https://github.com/right-0903/linux-gaokun) 提交 Issue，并附上内核版本、相关 `dmesg` 行和 `glxinfo -B` 输出。

涉及通用 Freedreno/Mesa 行为时，分别向 [Mesa](https://gitlab.freedesktop.org/mesa/mesa/-/issues) 或 [Linux DRM/msm](https://gitlab.freedesktop.org/drm/msm/-/issues) 提交最小复现；设备专属补丁不应直接提交到 Mesa。

触屏问题若能在其他 Himax 设备复现，可向 [Linux input 子系统](https://lore.kernel.org/linux-input/) 或对应触控驱动维护者报告；仅限 `gaokun3` 的 device tree、固件或内核补丁，应先提交到 [right-0903/linux-gaokun](https://github.com/right-0903/linux-gaokun)。本仓库适合接收脚本兼容性、回滚和文档改进的 Issue/PR。提交前请删去用户名、路径、序列号等隐私信息，并附上硬件型号、内核版本、日志和复现步骤。

## 文件说明

```text
docs/GPU_DRIVER_FIX.md         FD690 用户态故障的分析与修复记录
docs/TOUCH_LOW_FPS_FIX.md      Himax 低刷新率触屏故障的分析与修复记录
scripts/fix-gpu-userspace.sh   GPU 诊断、修复和回滚脚本
scripts/fix-touch-low-fps.sh   触屏诊断、修复和回滚脚本
LICENSE                        MIT License
```

## 许可证

本项目采用 MIT License，详见 [LICENSE](LICENSE)。
