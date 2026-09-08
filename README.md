# Adreno/Freedreno GPU Userspace Repair

用于诊断和修复 Qualcomm Adreno GPU 在 Ubuntu/Linux 上因全局用户态环境覆盖而回退到 `llvmpipe` 的小工具。项目不编译或安装内核，也不删除 GPU 库。

脚本最初在 Huawei MateBook E Go（`gaokun3`，Adreno 690/`FD690`）上验证，也适用于内核已经提供 MSM/Freedreno 支持的类似设备。

## 它解决什么问题

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

## 日志与配置

默认日志为 `~/gaokun-kernel-build/build.log`，可通过 `GPU_FIX_LOG` 覆盖；备份根目录可通过 `GPU_FIX_BACKUP_ROOT` 覆盖：

```bash
GPU_FIX_LOG=/tmp/gpu-driver-fix.log ./scripts/fix-gpu-userspace.sh --check
sudo GPU_FIX_BACKUP_ROOT=/var/backups/my-gpu-fix ./scripts/fix-gpu-userspace.sh --fix
```

## 适用范围与限制

本工具只处理“内核已支持 GPU，但用户态被错误环境变量覆盖”的情况。脚本无法确认 Adreno/Freedreno，或内核日志显示 GPU probe、GMU、固件初始化失败时，会拒绝修改。此时收集以下信息，交给设备内核适配项目或 Linux/Mesa 上游：

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

涉及通用 Freedreno/Mesa 行为时，分别向 [Mesa](https://gitlab.freedesktop.org/mesa/mesa/-/issues) 或 [Linux DRM/msm](https://gitlab.freedesktop.org/drm/msm/-/issues) 提交最小复现；设备专属补丁不应直接提交到 Mesa。脚本兼容性、回滚和文档改进可在本仓库开 Issue/PR，并请删去用户名、路径、序列号等隐私信息。

## 文件说明

```text
GPU_DRIVER_FIX.md              一次 FD690 故障的分析与修复记录
scripts/fix-gpu-userspace.sh   诊断、修复和回滚脚本
LICENSE                        MIT License
```

## 许可证

本项目采用 MIT License，详见 [LICENSE](LICENSE)。
