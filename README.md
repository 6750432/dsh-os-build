# DSH OS —— 用 mmdebstrap 从 Debian 手拼的整机系统

一套**构建脚本与文档**：从 Debian 13 (trixie) 的官方源出发，
用 `mmdebstrap` 一步步拼出一个能开机的完整桌面系统，全程不依赖任何发行版安装器。

**拼出来的系统里没有一个 Ubuntu / Mint 的包** —— 它是从 Debian 源码级组装起来的。

本仓库只放**脚本与文档**；rootfs、镜像、工具链等产物不入库（体积大、可重建）。

---

## 做出来的东西长什么样

| 项目 | 结果 |
|---|---|
| 发行版 | DSH OS 1.0（主机名 `dshos`，lightdm 自动登录） |
| 包数 | **1349**（对照：宿主 Linux Mint 2311） |
| 开机到图形界面 | 约 **11 秒** |
| 空载内存 | **474 MB** |
| 失败 systemd 单元 | 0 |
| 图形栈 | XFCE 4.20 |
| 验证 | gcc 14.2 在系统内真编译真跑 |

实测环境是 1 vCPU / 1 GB 内存的 QEMU 虚拟机（KVM 加速）。

---

## 脚本一览

```
拼装.sh              主脚本：从零拼出底座（mmdebstrap）
加包.sh              往已有 rootfs 里追加软件包组
本轮A-装QEMU和拼装.sh  一次性：装 QEMU + 拼装
本轮A-开机看桌面.sh    QEMU 开机并截图（走 QMP + VNC）
本轮B-做镜像和开机.sh  把 rootfs 做成可开机镜像
收尾.sh / 收尾C / 收尾E  时区、主机名、中文接线、直通能力等收尾
改名DSH-OS.sh         改名与品牌化（只动 rootfs，可重复跑，不需要 root）
启动DSH-OS.sh         直接启动现成镜像
补-QEMU图形后端.sh     宿主侧 QEMU 图形后端
装拼装工具.sh         宿主侧一次性准备
DSH-OS-看这里.txt      使用说明（先看这个）
进度.md               构建过程与踩坑记录
```

跑法（脚本需要 root，用 `pkexec` 弹密码框）：

```bash
pkexec bash ~/拼装/拼装.sh          # 拼一个最小系统
pkexec bash ~/拼装/本轮A-开机看桌面.sh   # 拼 + 开机 + 截图
```

---

## 三条硬护栏（都是事故换来的）

这套脚本内置了三条保护，**底线是不让构建过程拖垮宿主机器**：

1. **资源限额**：所有重活都套在
   `systemd-run --scope -p MemoryMax=4G -p MemorySwapMax=2G -p CPUQuota=250%` 里跑，
   脚本自己判断递归、开跑前检查可用内存，不够直接拒跑。
2. **隔离 `chroot` 的 `/dev` 与 `/run`**：在里面造**私有**的最小 `/dev`
   和**有大小上限**的 `/dev/shm`、`/run`，**绝不 rbind 宿主的对应目录**。
3. **挡住 postinst 启动服务**：用 `policy-rc.d` 防止包安装脚本去碰宿主的 init。

`进度.md` 里记了立这三条护栏的那次事故（构建把宿主机搞到 OOM），值得一读。

---

## 已知限制（诚实交代）

- **没测过真机安装**，只在 QEMU 里跑过。
- **显卡直通只把「能力」备好了，没真跑过一次**。脚本里写了怎么启用
  （`/etc/modprobe.d/dsh-vfio.conf` 里那行是**故意注释着**的）。
- 界面语言目前是**英文**。
- VM 里没有真显卡（vulkan 走 llvmpipe 软件渲染），吃 GPU 的程序会比较慢 —— 真机上不会有这个问题。
- 脚本内核启动参数里的那个根设备路径是**客机内部**的（由 QEMU 的 `-drive` 决定），与宿主分区无关。

---

## 许可 / License

MIT License。

- [`LICENSE`](LICENSE) —— 本项目自己的 MIT
- [`LICENSE-LOCAL`](LICENSE-LOCAL) —— 同一份，命名与其它仓库统一

```
Copyright (c) 2026 BZYS17Mintstar (6750432)
Generated with the assistance of AI (DeepSeek V4), guided by human architectural intuition.
```
