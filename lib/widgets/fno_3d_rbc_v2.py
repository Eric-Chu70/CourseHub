# -*- coding: utf-8 -*-
"""
FNO 3D RBC v2  ——  官方 Fourier Neural Operator (FNO3d) 在 RBC 数据集上的适配
================================================================================
目标: 用 zongyi-li/fourier_neural_operator 官方 FNO3d 模型, 在与 tf_sno_3d_rbc_v2.py
      完全相同的 RBC 训练管线 (3D 时序非定常瑞利-贝纳德自然对流) 上跑一遍,
      做"公平对比" —— 除 backbone 神经算子结构外, 其余逐项对齐。

公平对齐策略 (与 tf_sno_3d_rbc_v2.py 一致, 仅 [差异] 处不同):
  - 数据源 / 变量顺序 [u,v,w,T,p] / 网格 / mask / train|val|test 时间划分   : 完全一致 (直接 import)
  - 归一化统计 (场统计 in_mean/in_std, 增量统计 inc_mean/inc_std, 温度用 Tcorr=T-T_lin) : 完全一致
  - 输入噪声注入 (INPUT_NOISE_STD, 按各通道 in_std 比例)                      : 完全一致
  - 增量(残差)预测 + 边界条件硬约束 (vel_mask / y_mask / T_lin)               : 完全一致
  - 损失: 归一化增量空间 MSE = mean(((pred-next)/inc_std)^2)                  : 完全一致
  - 优化器: Adam(lr=1e-3) + CosineAnnealingLR(T_max=EPOCHS, eta_min=lr*0.1) + grad_clip : 完全一致
  - 训练循环: BATCH_SIZE / EPOCHS / 分层时间采样 / EMA 监控 / 固定验证集        : 完全一致
  - 监控指标 (归一化场上的 relL2/relH1, 逐通道 persistence skill)            : 完全一致
  - Rollout 评估 (RMSE/nRMSE/nRMSE_anom/MaxError/bRMSE/fRMSE/散度)           : 完全一致 (直接 import evaluate_rollout)
  - SEED = 3407                                                              : 完全一致
  [差异] backbone: TFSNO3D (谱块+门控+U-Net 下采样)  ->  官方 FNO3d (fc0 提升 + 4 谱卷积块 + fc1/fc2 投影)
  [差异] WIDTH / MODES: 默认沿用 20 / (12,12,12), 与 TFSNO 同 latent 宽度、同谱模态数, 便于横向对比

FNO3d 实现忠实于 zongyi-li/fourier_neural_operator 原版 (SpectralConv3d 用 4 组复数权重
覆盖 4 个频率象限; FNO3d: fc0 提升层 -> n_layers 个 (SpectralConv + 1x1 conv + GELU) 块
(末块不接 GELU) -> fc1 + GELU + fc2 投影)。唯一适配: backbone 入口接受 channels-first
(B,C,X,Y,Z) 张量, 与 TFSNO3D_RBC 的 backbone 调用接口 torch.cat([x_norm, coords], dim=1) 对齐。

用法:
    python fno_3d_rbc_v2.py             # 真实数据训练 (CFG.BASE_DIR 指向数据集)
    python fno_3d_rbc_v2.py --selftest  # 小尺寸合成数据自检
================================================================================
"""

import os
import time
import shutil
import tempfile
import argparse

import numpy as np
import pandas as pd
import torch
import torch.nn as nn
import torch.nn.functional as F

# ---- 直接复用 tf_sno_3d_rbc_v2 的全部共享基础设施, 保证除 backbone 外逐项一致 ----
# 数据源 / 网格 / mask / 归一化统计 / 采样 / 指标 / rollout 评估 全部来自同一份实现。
from tf_sno_3d_rbc_v2 import (
    CFG, VAR_ORDER, setup_seed, get_device, bottom_wall_temp,
    RBCH5DataSource, build_grid_and_masks,
    PairSampler, build_fixed_val_batch, estimate_norm_stats,
    normalize_state_for_metric,
    rel_L2_3d, rel_H1_3d, per_channel_skill_3d,
    rmse, nrmse, nrmse_anom, max_error, boundary_rmse,
    fourier_band_rmse, divergence_field, make_boundary_mask,
    count_params, evaluate_rollout, _make_synthetic_h5,
)


# ============================================================
# 官方 FNO3d (忠实于 zongyi-li/fourier_neural_operator)
# ============================================================
class SpectralConv3d(nn.Module):
    """官方 FNO 的 3D 谱卷积。
    rfftn 后用 4 组可学习复数权重分别乘 4 个频率象限 (前两维正/负频率组合,
    第三维因 rfftn 只保留正频率), 再 irfftn 回空间域。norm='ortho' 与原版一致。
    """

    def __init__(self, in_channels, out_channels, modes1, modes2, modes3):
        super().__init__()
        self.in_channels = in_channels
        self.out_channels = out_channels
        # modes 不超过 floor(N/2)+1
        self.modes1 = modes1
        self.modes2 = modes2
        self.modes3 = modes3
        self.scale = 1.0 / (in_channels * out_channels)
        self.weights1 = nn.Parameter(self.scale * torch.rand(
            in_channels, out_channels, modes1, modes2, modes3, dtype=torch.cfloat))
        self.weights2 = nn.Parameter(self.scale * torch.rand(
            in_channels, out_channels, modes1, modes2, modes3, dtype=torch.cfloat))
        self.weights3 = nn.Parameter(self.scale * torch.rand(
            in_channels, out_channels, modes1, modes2, modes3, dtype=torch.cfloat))
        self.weights4 = nn.Parameter(self.scale * torch.rand(
            in_channels, out_channels, modes1, modes2, modes3, dtype=torch.cfloat))

    def compl_mul3d(self, input, weights):
        # (B, in, m1, m2, m3) x (in, out, m1, m2, m3) -> (B, out, m1, m2, m3)
        return torch.einsum("bixyz,ioxyz->boxyz", input, weights)

    def forward(self, x):
        batchsize = x.shape[0]
        size1, size2, size3 = x.shape[-3], x.shape[-2], x.shape[-1]
        x_ft = torch.fft.rfftn(x, dim=[-3, -2, -1], norm="ortho")
        out_ft = torch.zeros(batchsize, self.out_channels, size1, size2,
                             size3 // 2 + 1, dtype=torch.cfloat, device=x.device)
        out_ft[:, :, :self.modes1, :self.modes2, :self.modes3] = \
            self.compl_mul3d(x_ft[:, :, :self.modes1, :self.modes2, :self.modes3], self.weights1)
        out_ft[:, :, -self.modes1:, :self.modes2, :self.modes3] = \
            self.compl_mul3d(x_ft[:, :, -self.modes1:, :self.modes2, :self.modes3], self.weights2)
        out_ft[:, :, :self.modes1, -self.modes2:, :self.modes3] = \
            self.compl_mul3d(x_ft[:, :, :self.modes1, -self.modes2:, :self.modes3], self.weights3)
        out_ft[:, :, -self.modes1:, -self.modes2:, :self.modes3] = \
            self.compl_mul3d(x_ft[:, :, -self.modes1:, -self.modes2:, :self.modes3], self.weights4)
        return torch.fft.irfftn(out_ft, s=(size1, size2, size3), dim=[-3, -2, -1], norm="ortho")


class FNO3d(nn.Module):
    """官方 FNO3d 结构: fc0 提升 -> n_layers 个 (SpectralConv + 1x1 conv + GELU) 块
    (末块不接 GELU, 与原版一致) -> fc1 + GELU + fc2 投影。

    入口接受 channels-first (B, in_ch, X, Y, Z), 内部 permute 到 (B,X,Y,Z,C) 走 Linear,
    谱卷积在 channels-first 上做, 出口再回到 channels-first —— 仅这一处为适配 RBC 外壳
    调用接口做的张量布局调整, 架构本身与原版完全一致。
    """

    def __init__(self, modes1, modes2, modes3, width, in_ch, out_ch, n_layers=4):
        super().__init__()
        self.modes1, self.modes2, self.modes3 = modes1, modes2, modes3
        self.width = width
        self.n_layers = n_layers
        self.fc0 = nn.Linear(in_ch, self.width)
        self.convs = nn.ModuleList([
            SpectralConv3d(self.width, self.width, modes1, modes2, modes3)
            for _ in range(n_layers)
        ])
        self.ws = nn.ModuleList([
            nn.Conv3d(self.width, self.width, 1) for _ in range(n_layers)
        ])
        self.fc1 = nn.Linear(self.width, 128)
        self.fc2 = nn.Linear(128, out_ch)

    def forward(self, x):
        # x: (B, in_ch, X, Y, Z)
        x = x.permute(0, 2, 3, 4, 1)               # (B, X, Y, Z, in_ch)
        x = self.fc0(x)                             # (B, X, Y, Z, width)
        x = x.permute(0, 4, 1, 2, 3)               # (B, width, X, Y, Z)
        for i in range(self.n_layers):
            x1 = self.convs[i](x)
            x2 = self.ws[i](x)
            x = x1 + x2
            if i < self.n_layers - 1:
                x = F.gelu(x)
        x = x.permute(0, 2, 3, 4, 1)               # (B, X, Y, Z, width)
        x = F.gelu(self.fc1(x))                     # (B, X, Y, Z, 128)
        x = self.fc2(x)                             # (B, X, Y, Z, out_ch)
        x = x.permute(0, 4, 1, 2, 3)               # (B, out_ch, X, Y, Z)
        return x


# ============================================================
# 顶层模型: 归一化输入 + 增量预测 + 边界条件硬约束 (与 TFSNO3D_RBC 完全同构, 仅换 backbone)
# ============================================================
class FNO3D_RBC(nn.Module):
    """
    forward(state_now, t_now_phys, t_next_phys) -> state_next
    通道顺序恒为 VAR_ORDER = [u, v, w, T, p]。

    输入归一化: x_norm = ([u,v,w, T - T_lin(y,t_now), p] - in_mean) / in_std
    输出 (增量式, 与 TFSNO3D_RBC 完全一致):
        u_{n+1} = u_n + vel_mask * du            (六壁无滑移, 由数据壁面值逐步精确传递)
        T_{n+1} = T_n + [T_lin(t_{n+1}) - T_lin(t_n)] + y_mask * dTcorr
                                              (顶/底 Dirichlet 精确成立)
        p_{n+1} = p_n + dp                        (无解析边界条件)
    其中 d* = raw * inc_std + inc_mean, raw = backbone([x_norm, coords])。

    [差异] 唯一与 TFSNO3D_RBC 不同之处: self.backbone = FNO3d(...) (官方 FNO3d)。
    """

    def __init__(self, cfg: CFG, grid_info: dict):
        super().__init__()
        self.cfg = cfg
        mx, my, mz = cfg.MODES
        n_layers = getattr(cfg, "FNO_N_LAYERS", 4)
        self.backbone = FNO3d(modes1=mx, modes2=my, modes3=mz,
                              width=cfg.WIDTH, in_ch=5 + 3, out_ch=5,
                              n_layers=n_layers)
        self.register_buffer("coords", grid_info["coords"])
        self.register_buffer("vel_mask", grid_info["vel_mask"])
        self.register_buffer("y_mask", grid_info["y_mask"])
        self.register_buffer("y_n", grid_info["y_n"])
        # 场统计 (输入归一化) + 增量统计 (输出缩放/损失归一化), 与 TFSNO3D_RBC 同名同义
        self.register_buffer("in_mean", torch.zeros(5))
        self.register_buffer("in_std", torch.ones(5))
        self.register_buffer("inc_mean", torch.zeros(5))
        self.register_buffer("inc_std", torch.ones(5))

    def set_norm_stats(self, in_mean, in_std, inc_mean, inc_std):
        device = self.in_mean.device
        self.in_mean = torch.as_tensor(in_mean, dtype=torch.float32, device=device)
        self.in_std = torch.as_tensor(in_std, dtype=torch.float32, device=device)
        self.inc_mean = torch.as_tensor(inc_mean, dtype=torch.float32, device=device)
        self.inc_std = torch.as_tensor(inc_std, dtype=torch.float32, device=device)

    def _T_lin(self, t_phys, B, device):
        t_t = torch.as_tensor(t_phys, dtype=torch.float32, device=device)
        Th = bottom_wall_temp(t_t, self.cfg).view(B, 1, 1, 1, 1)
        return Th + (self.cfg.T_TOP - Th) * self.y_n.expand(B, -1, -1, -1, -1)

    def forward(self, state_now, t_now_phys, t_next_phys):
        B = state_now.shape[0]
        device = state_now.device
        T_lin_now = self._T_lin(t_now_phys, B, device)
        T_lin_next = self._T_lin(t_next_phys, B, device)

        # 归一化输入 (温度用异常量 T - T_lin)
        x = state_now.clone()
        x[:, 3:4] = x[:, 3:4] - T_lin_now
        x_norm = (x - self.in_mean.view(1, -1, 1, 1, 1)) / self.in_std.view(1, -1, 1, 1, 1)

        coords = self.coords.expand(B, -1, -1, -1, -1)
        raw = self.backbone(torch.cat([x_norm, coords], dim=1))  # (B,5,X,Y,Z)
        d = raw * self.inc_std.view(1, -1, 1, 1, 1) + self.inc_mean.view(1, -1, 1, 1, 1)

        vel_mask = self.vel_mask.expand(B, -1, -1, -1, -1)
        y_mask = self.y_mask.expand(B, -1, -1, -1, -1)

        # 增量式硬约束 (与 TFSNO3D_RBC 完全一致)
        u = state_now[:, 0:1] + vel_mask * d[:, 0:1]
        v = state_now[:, 1:2] + vel_mask * d[:, 1:2]
        w = state_now[:, 2:3] + vel_mask * d[:, 2:3]
        T = state_now[:, 3:4] + (T_lin_next - T_lin_now) + y_mask * d[:, 3:4]
        p = state_now[:, 4:5] + d[:, 4:5]
        return torch.cat([u, v, w, T, p], dim=1)


# ============================================================
# 训练 (与 train_tfsno3d 逐行对齐, 仅 model 类与 SAVE_DIR 不同)
# ============================================================
def train_fno3d(cfg: CFG, src: "RBCH5DataSource" = None):
    setup_seed(cfg.SEED)
    device = get_device()
    print(f"[INFO] device = {device}    [FNO3D] backbone = 官方 FNO3d "
          f"(width={cfg.WIDTH}, modes={tuple(cfg.MODES)}, "
          f"n_layers={getattr(cfg, 'FNO_N_LAYERS', 4)})")

    own_src = src is None
    if own_src:
        src = RBCH5DataSource(cfg)

    os.makedirs(cfg.SAVE_DIR, exist_ok=True)
    grid_info = build_grid_and_masks(src, cfg, device)
    sampler = PairSampler(src, cfg)

    model = FNO3D_RBC(cfg, grid_info).to(device)
    in_mean, in_std, inc_mean, inc_std = estimate_norm_stats(src, cfg, cfg.NORM_STAT_SAMPLES)
    model.set_norm_stats(in_mean, in_std, inc_mean, inc_std)
    print(f"[INFO] params = {count_params(model):,}  "
          f"(对照 TFSNO3D 默认配置可看参数量差异; 两侧 WIDTH/MODES 已对齐)")
    print(f"[INFO] in_mean (u,v,w,Tcorr,p) = {in_mean}")
    print(f"[INFO] in_std  (u,v,w,Tcorr,p) = {in_std}")
    print(f"[INFO] inc_std (du,dv,dw,dTcorr,dp) = {inc_std}")

    opt = torch.optim.Adam(model.parameters(), lr=cfg.LR)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=cfg.EPOCHS, eta_min=cfg.LR * 0.1)

    inc_std_t = model.inc_std.view(1, -1, 1, 1, 1)
    in_std_t = model.in_std.view(1, -1, 1, 1, 1)

    val_batch = build_fixed_val_batch(src, cfg, device)
    if val_batch is not None:
        print(f"[INFO] 固定验证集: {cfg.N_VAL_PAIRS} 对样本, 取自 val_t_idx "
              f"[{src.val_t_indices[0]},{src.val_t_indices[-1]}]")

    ema = {"loss": None, "relL2n": None, "relH1n": None}

    def _update_ema(key, value):
        ema[key] = value if ema[key] is None else cfg.EMA_DECAY * ema[key] + (1 - cfg.EMA_DECAY) * value
        return ema[key]

    log_rows = []
    t_start = time.time()
    for ep in range(1, cfg.EPOCHS + 1):
        model.train()
        opt.zero_grad(set_to_none=True)

        state_now, state_next, t_now_phys, t_next_phys = sampler.sample_batch(cfg.BATCH_SIZE, device)

        # 输入噪声注入 (与 tfsno 完全一致): 提升自回归 rollout 稳定性
        state_in = state_now
        if cfg.INPUT_NOISE_STD and cfg.INPUT_NOISE_STD > 0:
            state_in = state_now + torch.randn_like(state_now) * (in_std_t * cfg.INPUT_NOISE_STD)

        pred_next = model(state_in, t_now_phys, t_next_phys)

        # 损失按增量标准差归一化 (归一化增量空间 MSE), 与 tfsno 完全一致
        diff = (pred_next - state_next) / inc_std_t
        loss = torch.mean(diff ** 2)

        loss.backward()
        if cfg.GRAD_CLIP and cfg.GRAD_CLIP > 0:
            torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=cfg.GRAD_CLIP)
        opt.step()
        sched.step()

        if ep % cfg.PRINT_EVERY == 0 or ep == 1:
            with torch.no_grad():
                # 在归一化场上算合并 relL2/relH1 + 逐通道 persistence skill
                pn = normalize_state_for_metric(pred_next, t_next_phys, model)
                tn = normalize_state_for_metric(state_next, t_next_phys, model)
                rel_l2_n = float(rel_L2_3d(pn, tn, src.dx, src.dy, src.dz))
                rel_h1_n = float(rel_H1_3d(pn, tn, src.dx, src.dy, src.dz))
                skill = per_channel_skill_3d(pred_next, state_next, state_now)
            ema_loss = _update_ema("loss", loss.item())
            ema_l2 = _update_ema("relL2n", rel_l2_n)
            ema_h1 = _update_ema("relH1n", rel_h1_n)
            skill_str = ", ".join(f"{n}={v:.3f}" for n, v in zip(VAR_ORDER, skill))
            print(f"[FNO3D] ep {ep:6d}/{cfg.EPOCHS} lr={sched.get_last_lr()[0]:.3e} "
                  f"loss={loss.item():.4e}(ema {ema_loss:.4e}) "
                  f"relL2_norm={rel_l2_n:.4e}(ema {ema_l2:.4e}) "
                  f"relH1_norm={rel_h1_n:.4e}(ema {ema_h1:.4e}) | skill(vs persist): {skill_str}")
            log_rows.append({"epoch": ep, "loss": loss.item(), "loss_ema": ema_loss,
                             "relL2_norm": rel_l2_n, "relH1_norm": rel_h1_n,
                             **{f"skill_{n}": float(v) for n, v in zip(VAR_ORDER, skill)}})

        if val_batch is not None and (ep % cfg.VAL_EVERY == 0 or ep == cfg.EPOCHS):
            model.eval()
            with torch.no_grad():
                v_now, v_next, vt_now, vt_next = val_batch
                v_pred = model(v_now, vt_now, vt_next)
                vpn = normalize_state_for_metric(v_pred, vt_next, model)
                vtn = normalize_state_for_metric(v_next, vt_next, model)
                v_l2 = float(rel_L2_3d(vpn, vtn, src.dx, src.dy, src.dz))
                v_h1 = float(rel_H1_3d(vpn, vtn, src.dx, src.dy, src.dz))
                v_skill = per_channel_skill_3d(v_pred, v_next, v_now)
            model.train()
            skill_str = ", ".join(f"{n}={v:.3f}" for n, v in zip(VAR_ORDER, v_skill))
            print(f"          [VAL fixed set] relL2_norm={v_l2:.4e} relH1_norm={v_h1:.4e} "
                  f"| skill(vs persist): {skill_str}")
            log_rows.append({"epoch": ep, "val_relL2_norm": v_l2, "val_relH1_norm": v_h1,
                             **{f"val_skill_{n}": float(v) for n, v in zip(VAR_ORDER, v_skill)}})

    train_time = time.time() - t_start
    pd.DataFrame(log_rows).to_csv(os.path.join(cfg.SAVE_DIR, "train_log.csv"), index=False)
    torch.save({
        "state_dict": model.state_dict(),
        "in_mean": in_mean, "in_std": in_std, "inc_mean": inc_mean, "inc_std": inc_std,
        "config": {k: v for k, v in vars(cfg).items() if not k.startswith("__")},
        "backbone": "FNO3d",  # 标记, 供 test 脚本区分
    }, os.path.join(cfg.SAVE_DIR, "fno3d_rbc_final.pt"))
    print(f"[INFO] 训练耗时 {train_time:.1f}s, checkpoint 已保存到 {cfg.SAVE_DIR}")

    df_metrics = evaluate_rollout(model, src, cfg, device)  # 与 tfsno 完全同一份评估函数
    df_metrics.to_csv(os.path.join(cfg.SAVE_DIR, "rollout_metrics.csv"), index=False)
    print("\n===== Rollout 评估 (自回归多步, 口径与 TFSNO 完全一致) =====")
    print(df_metrics.groupby("var")[["RMSE", "nRMSE_anom", "MaxError", "bRMSE"]].mean())

    if own_src:
        src.close()
    return model, df_metrics


# ============================================================
# 自检 (与 tfsno run_selftest 同构, 仅换模型与 SAVE_DIR)
# ============================================================
def run_selftest():
    print("[SELFTEST] 使用小尺寸合成数据 (8^3 网格, T=6) 跑通整条 FNO3D pipeline ...")
    tmp_dir = tempfile.mkdtemp(prefix="fno3d_selftest_")
    try:
        _make_synthetic_h5(tmp_dir, nx=8, ny=8, nz=8, B=1, T=6, dt=0.1)

        cfg = CFG()
        cfg.BASE_DIR = tmp_dir
        cfg.WIDTH = 6
        cfg.MODES = (3, 3, 3)
        cfg.FNO_N_LAYERS = 4
        cfg.BATCH_SIZE = 1
        cfg.EPOCHS = 5
        cfg.PRINT_EVERY = 1
        cfg.NORM_STAT_SAMPLES = 2
        cfg.TEST_TIME_FRACTION = 0.34
        cfg.VAL_TIME_FRACTION = 0.16
        cfg.N_VAL_PAIRS = 2
        cfg.VAL_EVERY = 2
        cfg.N_TEST_SNAPSHOTS = 1
        cfg.ROLLOUT_STEPS = 1
        cfg.SAVE_DIR = os.path.join(tmp_dir, "results")

        model, df_metrics = train_fno3d(cfg)
        assert not df_metrics.empty, "rollout 评估结果为空"
        core = df_metrics.loc[df_metrics["var"] != "continuity(div_u)", "RMSE"]
        assert np.isfinite(core).all(), "评估指标里出现了 NaN/Inf"
        print("[SELFTEST] 通过: forward/backward/评估全部正常, 没有出现 NaN/Inf。")
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--selftest", action="store_true", help="用小尺寸合成数据跑一次自检")
    parser.add_argument("--no-cache-ram", action="store_true",
                        help="关闭整数据集内存缓存 (默认开启, 以避开 HDD 随机读瓶颈)")
    parser.add_argument("--batch_size", type=int, default=None, help="覆盖 CFG.BATCH_SIZE")
    args = parser.parse_args()

    if args.selftest:
        run_selftest()
        return

    cfg = CFG()
    cfg.FNO_N_LAYERS = getattr(cfg, "FNO_N_LAYERS", 4)
    if args.batch_size is not None:
        cfg.BATCH_SIZE = args.batch_size
    cfg.SAVE_DIR = f"./results_FNO3D_RBC_v2_{cfg.TIMESTAMP}"
    if not os.path.isdir(cfg.BASE_DIR):
        print(f"[WARN] 未找到真实数据目录 {cfg.BASE_DIR}, 自动退化为自检模式。")
        run_selftest()
        return

    # HDD 上 HDF5 随机读是训练吞吐瓶颈 (你刚才 KeyboardInterrupt 就是卡在这)。
    # 默认把全部数据缓存进内存 (float32): B*T*nx*ny*nz*5*4 bytes,
    # B=1/T=4344/64^3 时约 22.8 GB。需要空闲内存 >= ~24 GB。
    # 内存不够时加 --no-cache-ram 关闭 (但 HDD 上每步读盘会很慢)。
    if not args.no_cache_ram:
        cfg.CACHE_IN_RAM = True
        print(f"[INFO] 已开启 CACHE_IN_RAM (首次顺序读一遍后训练期间不再碰磁盘)。\n"
              f"       若内存不足导致 OOM, 用 --no-cache-ram 关闭。")

    train_fno3d(cfg)


if __name__ == "__main__":
    main()
