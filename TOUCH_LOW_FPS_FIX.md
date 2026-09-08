# 低刷新率下触屏短点击修复说明

## 现象

在 Huawei MateBook E Go（`gaokun3`）上，将屏幕切换到较低刷新率后，快速点击可能没有反应；保持手指稍久，或切回 120 Hz 后，点击恢复正常。这里的“触屏不灵敏”不是 Adreno GPU 渲染器问题，而是当前 Himax HX83121A 触控驱动的**按帧起始防抖**：触点需要经过若干个触控帧才会上报，过短的按下—抬起序列会在驱动内部被过滤。

本机已经确认触控设备为：

```text
Himax Capacitive TouchScreen
modalias: spi:hx83121a-ts
driver: himax-spi
```

并且驱动暴露了以下运行时调参节点：

```text
.../algo/debounce_base
.../algo/track_start_debounce
```

当前值曾观察到：

```text
debounce_base=2
track_start_debounce=3
```

这些值是**帧数**而不是毫秒。刷新/触控报告频率降低时，同样的防抖帧数对应的时间窗口会变长，因此短点击更容易在正式上报前结束。120 Hz 下窗口变短，所以问题不明显。

## 修复策略

之前将起始防抖直接设为 `0/0` 后，短点击更容易识别，但拖动可能因为触控报告短暂丢帧而被提前结束。当前改用“短点击 + 连续拖动平衡”配置：

```text
debounce_base=0
track_start_debounce=0
track_lost_frames=8
```

其中：

- `debounce_base=0` 和 `track_start_debounce=0`：保留快速按下的响应速度；
- `track_lost_frames=8`：允许连续触控过程中暂时丢失若干触控帧，避免拖动被过早拆成抬起/重新按下。

本机原值 `track_lost_frames=3` 偏向快速结束触点。提高到 `8` 是针对低刷新率/低报告率拖动的折中值。它只修改 Himax 驱动的 sysfs 算法参数，不替换内核、不重编译驱动、不修改显示模式，也不会修改 GPU 用户态库。

代价是实际抬手后，驱动可能额外保留触点若干帧；如果出现拖动松手反应变慢、粘滞或误触，可依次尝试 `6` 或 `4`：

```bash
sudo TOUCH_LOST_FRAMES=6 ./scripts/fix-touch-low-fps.sh --fix
```

如果短点击仍然漏判，可把起始参数改为 `1/1`；但这会重新引入一帧起始等待：

```bash
sudo TOUCH_DEBOUNCE_BASE=1 TOUCH_START_DEBOUNCE=1 TOUCH_LOST_FRAMES=8 \
  ./scripts/fix-touch-low-fps.sh --fix
```

## 使用方法

### 1. 先诊断

```bash
./scripts/fix-touch-low-fps.sh --check
```

重点确认输出包含：

```text
Found ... Himax tuning node(s).
node: .../algo
debounce_base        0
track_start_debounce 0
track_lost_frames    3
```

如果找不到节点，脚本会拒绝修改；不要把本脚本用于其他触摸屏驱动。

### 2. 应用并持久化

```bash
sudo ./scripts/fix-touch-low-fps.sh --fix
```

脚本会：

1. 在 `/var/backups/gpu-driver-fix/<时间>-touch/values.tsv` 保存原值；
2. 立即写入三个 sysfs 参数；
3. 安装 `gaokun3-touch-responsive.service`，开机后自动重新应用；
4. 将过程追加到 `~/gaokun-kernel-build/build.log`（若以 `sudo` 运行，请用 `TOUCH_FIX_LOG` 明确指定普通用户日志路径）。

不需要注销或重启即可测试当前触屏；如果安装了持久化服务，后续启动也会自动应用。脚本不会自动执行 `reboot`。

### 3. 验证

建议分别在低刷新率和 120 Hz 下，用同一应用进行快速点击测试。也可以观察内核输入事件：

```bash
sudo evtest /dev/input/event11
```

实际 event 编号可能变化，先用下面命令确认 Himax 对应的设备：

```bash
grep -l 'Himax Capacitive TouchScreen' /sys/class/input/input*/name
```

确认没有明显误触、松手粘滞或拖动断裂后，再测试点击、滑动和多指输入。GPU 验证仍使用原来的命令：

```bash
glxinfo -B | grep -E 'OpenGL vendor|OpenGL renderer'
```

### 4. 回滚

`--fix` 会打印备份目录，例如：

```bash
sudo ./scripts/fix-touch-low-fps.sh --rollback \
  /var/backups/gpu-driver-fix/20260908T200000+0800-touch
```

回滚只恢复当时保存的 sysfs 参数，不会删除内核或驱动。若不希望开机继续覆盖参数，可执行：

```bash
sudo ./scripts/fix-touch-low-fps.sh --uninstall
```

然后再执行 `--rollback`。

## 与 GPU 修复的关系

GPU 的 `FD690` 硬件加速已经恢复；本问题发生在另一个层次：Himax SPI 触控驱动的输入过滤。不要通过重新启用 `MESA_LOADER_DRIVER_OVERRIDE=zink`、修改 GBM、安装 NVIDIA 驱动或改变 GPU 频率来解决触控问题。

如果调参后仍然漏点，应使用 `evtest` 判断：

- 如果 `/dev/input` 本身没有产生按下/抬起事件，问题在触控芯片、SPI、驱动算法或固件；
- 如果内核事件完整，但应用没有点击，问题在桌面/应用输入处理，应另行检查 GNOME/Mutter、XWayland 或应用自身；
- 如果低刷新率下只有画面卡顿而输入事件完整，则可能是合成器延迟，不应继续降低触控防抖。

本修复不保证所有 Himax 固件或其他触控芯片适用；脚本通过 driver/modalias 检测后才会自动修改。
