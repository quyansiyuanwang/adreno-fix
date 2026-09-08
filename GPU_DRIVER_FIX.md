# Adreno/Freedreno GPU 驱动故障修复记录与工具说明

> 历史案例：本文记录 `gaokun3`/FD690 的一次实际故障，不把其中的内核版本或路径视为其他设备的要求。

## 1. 问题概述

本机是 Huawei MateBook E Go（`gaokun3`），SoC 为 Qualcomm SC8280XP，GPU 为 Adreno 690。最初表现为桌面图形程序使用 `llvmpipe` 软件渲染。

经过检查，问题不是 NVIDIA 驱动缺失，也不是内核未支持 GPU：

- 当前内核为 `7.2.0-rc4-gaokun3+`；
- `3d00000.gpu` 已绑定内核 `adreno` 驱动；
- `msm` DRM 驱动已初始化；
- `qcom/a660_sqe.fw` 和 `qcom/a660_gmu.bin` 已加载；
- Xorg 日志显示过 `glamor X acceleration enabled on FD690`；
- Mesa 的 `msm_dri.so` 已安装。

真正原因是系统级图形环境覆盖强制使用 Zink 和自定义 GBM 后端：

```text
/etc/environment.d/adreno.conf
MESA_LOADER_DRIVER_OVERRIDE=zink
GBM_BACKENDS_PATH=/usr/local/lib/aarch64-linux-gnu/adreno/gbm
VK_DRIVER_FILES=freedreno_icd.json
```

同时 `/etc/profile.d/adreno.sh` 也设置了自定义 GBM/Vulkan 路径。Zink 的 Vulkan 初始化失败后，Mesa 回退到 `llvmpipe`。

## 2. 已执行的修复

只禁用了两个全局覆盖文件，并保留了原文件及自定义库：

```text
/etc/environment.d/adreno.conf.disabled
/etc/profile.d/adreno.sh.disabled
```

没有执行以下危险操作：

- 没有安装或卸载 NVIDIA 驱动；
- 没有删除当前内核；
- 没有重新编译内核；
- 没有修改 GRUB 或内核启动参数；
- 没有删除 `/usr/local/lib/aarch64-linux-gnu/adreno/` 下的库；
- 没有自动重启。

注销并重新登录后，实际桌面终端验证结果为：

```text
no graphics overrides
OpenGL vendor string: freedreno
OpenGL renderer string: FD690
OpenGL core profile renderer: FD690
OpenGL compatibility profile renderer: FD690
OpenGL ES profile renderer: FD690
```

这证明默认桌面 OpenGL/OpenGL ES 已经使用 Adreno 690 硬件加速。

## 3. 通用修复脚本

脚本位置：

```text
scripts/fix-gpu-userspace.sh
```

它面向同类 Qualcomm Adreno/Freedreno 问题，默认只处理用户态全局环境覆盖：

- 检测 Adreno/Freedreno 内核绑定；
- 检查 `/etc/environment.d/*.conf` 和 `/etc/profile.d/*.sh`；
- 识别强制 `MESA_LOADER_DRIVER_OVERRIDE=zink`、自定义 Adreno GBM 后端和相关 Vulkan 覆盖；
- 修改前将文件保存到 `/var/backups/gpu-driver-fix/<timestamp>/`；
- 在备份目录写入 `manifest`，记录本次实际修改的文件；
- 将配置改名为 `.disabled.<timestamp>`，而非删除；
- 输出 GLX/EGL 渲染器；
- 记录到 `$HOME/gaokun-kernel-build/build.log`，也可用 `GPU_FIX_LOG` 覆盖；
- 不修改内核、软件包、GRUB，不执行重启。

### 3.1 只诊断

```bash
./scripts/fix-gpu-userspace.sh --check
```

### 3.2 执行修复

```bash
sudo ./scripts/fix-gpu-userspace.sh --fix
```

执行后注销并重新登录，或在确认可以重启时手动重启。已有的 GNOME Shell、Xwayland 和终端进程会继续保留旧环境变量，不能在同一旧进程中判断修复是否生效。

### 3.3 验证

```bash
env | grep -E '^(MESA|LIBGL|EGL|GBM|DRI|VK_|GALLIUM)' || echo 'no graphics overrides'
glxinfo -B | grep -E 'OpenGL vendor|OpenGL renderer'
eglinfo -B | grep -E 'OpenGL .*renderer|EGL vendor|MESA: error|libEGL warning'
```

成功标准：默认 `OpenGL renderer` 为 `FD690`、`Adreno` 或其他 Freedreno 硬件标识，而不是 `llvmpipe`。

`eglinfo -B` 可能同时列出多个 EGL 平台/设备，其中某个备用平台显示 `llvmpipe` 不一定表示桌面渲染失败；应优先查看 `glxinfo -B` 的默认 renderer 和 EGL 输出中的硬件平台。

### 3.4 回滚

脚本执行 `--fix` 后会打印备份目录。例如：

```bash
sudo ./scripts/fix-gpu-userspace.sh --rollback \
  /var/backups/gpu-driver-fix/20260908T190000+0800
```

回滚后同样需要注销并重新登录。回滚会恢复原来的覆盖配置，因此可能重新触发 Zink/`llvmpipe` 问题。
如果目标文件已被用户重新创建，脚本会拒绝覆盖并报告未完成的回滚。

## 4. 失败时的边界

如果 `--check` 无法确认 Adreno/Freedreno，脚本会拒绝自动修改。此时应先人工检查：

```bash
uname -a
cat /proc/cmdline
readlink -f /sys/bus/platform/devices/3d00000.gpu/driver
journalctl -b -k | grep -iE 'msm|adreno|a6xx|gmu|firmware|drm'
ls -l /dev/dri
```

只有在内核日志确认 GPU 没有成功初始化时，才应转到设备内核适配项目或 Linux/Mesa 上游重新评估 device tree、补丁、内核配置和固件；不要因为 `nvidia-smi` 不存在就给 ARM Qualcomm 设备安装 NVIDIA 驱动。
