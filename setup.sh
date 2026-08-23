#!/usr/bin/env bash
# saniora setup — cài ComfyUI + tải models H3 + venv API trong 1 lệnh.
#
# Usage:
#   bash scripts/setup.sh
#   COMFYUI_DIR=/opt/ComfyUI bash scripts/setup.sh   # thư mục cài ComfyUI
#   HF_TOKEN=hf_xxx bash scripts/setup.sh            # model gated cần auth
#   SKIP_COMFYUI=1 bash scripts/setup.sh             # đã có ComfyUI rồi
#   SKIP_MODELS=1  bash scripts/setup.sh             # đã tải models rồi
#   SKIP_TURBO_LORA=1 bash scripts/setup.sh          # đã có Turbo LoRA rồi / không cần Turbo
#   SKIP_API=1     bash scripts/setup.sh             # đã có venv API rồi
#   COMFYUI_REF=v0.31.1 bash scripts/setup.sh         # pin version ComfyUI (mặc định v0.31.1,
#                                                      # tránh regression H3 chậm ~4x ở v0.32.0+)
#   MODEL_ROOT=/workspace/models bash scripts/setup.sh
#       # models đã tải sẵn (hoặc sẽ được tải vào) một thư mục RIÊNG, tách khỏi
#       # COMFYUI_DIR — hữu ích khi ComfyUI nằm trong container tạm còn model
#       # nằm trên Network Volume RunPod, muốn giữ nguyên qua các lần rebuild.
#       # setup.sh sẽ symlink $COMFYUI_DIR/models -> $MODEL_ROOT, mọi download
#       # sau đó vào thẳng $MODEL_ROOT nên lần chạy sau (volume vẫn còn) sẽ
#       # tự skip vì file đã có sẵn.
#
# Idempotent: clone/download chỉ cái thiếu, cái có sẵn thì bỏ qua.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMFYUI_DIR="${COMFYUI_DIR:-/workspace/saniora/ComfyUI}"
MODEL_ROOT="${MODEL_ROOT:-$COMFYUI_DIR/models}"
COMFYUI_GIT_URL="https://github.com/comfyanonymous/ComfyUI"
# Pin: ComfyUI v0.32.0 (11/8/2026) trở lên có regression làm MiniMax H3 chậm
# ~4x ở full-res, do PR #15486 ("fix peak memory issue with H3", v = v.clone())
# — xem https://github.com/Comfy-Org/ComfyUI/issues/15665 (còn open, xác nhận
# ảnh hưởng cả v0.33.1). v0.31.1 đã có đầy đủ MiniMax H3 R2V (native từ
# v0.30.0, 3/8/2026: 9 ref ảnh + 3 ref video + 3 ref audio) và KHÔNG dính
# regression này — override bằng COMFYUI_REF=<tag/commit> nếu upstream đã fix.
COMFYUI_REF="${COMFYUI_REF:-v0.31.1}"
HF_TOKEN="${HF_TOKEN:-}"
PY="${PY:-python3}"

# repo|repo_relative_path|target_subdir_trong_models|revision (commit SHA, pinned
# 2026-08-23 — xem docs/MiniMax_H3_Turbo_LoRA_Implementation_Guide.md; đổi revision
# ở đây có chủ đích sau khi đã benchmark, không để `hf download` tự trôi theo main)
LORAS=(
  "drbaph/MiniMax-H3-Turbo-Lora-ComfyUI|minimax_h3_turbo_v4_step600_ema_pruned_comfyui.safetensors|loras|4728c77ec8c0a32b9ec62a128f6c118372f5fa1f"
  "lightx2v/Minimax-h3-Turbo|minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors|loras|ec01fa4c86263832faa0bd1d6d8f36a281eaabb2"
)
MODELS=(
  "Comfy-Org/MiniMax-H3|diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors|diffusion_models|6701b0a14feefd7141bd9cfe8386961c27007622"
  "Comfy-Org/MiniMax-H3|diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors|diffusion_models|6701b0a14feefd7141bd9cfe8386961c27007622"
  "Comfy-Org/MiniMax-H3|text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors|text_encoders|6701b0a14feefd7141bd9cfe8386961c27007622"
  "Comfy-Org/MiniMax-H3|vae/minimax_h3_video_vae_fp16.safetensors|vae|6701b0a14feefd7141bd9cfe8386961c27007622"
  "Comfy-Org/MiniMax-H3|vae/minimax_h3_audio_vae_fp32.safetensors|vae|6701b0a14feefd7141bd9cfe8386961c27007622"
)

step() { printf '\n==> %s\n' "$1"; }

# --- 1. ComfyUI -------------------------------------------------------------
if [ "${SKIP_COMFYUI:-0}" = "1" ]; then
  step "SKIP_COMFYUI=1 — bỏ qua cài ComfyUI"
else
  if [ -d "$COMFYUI_DIR/.git" ]; then
    step "ComfyUI đã có tại $COMFYUI_DIR — bỏ qua clone"
    echo "   (đang ở: $(git -C "$COMFYUI_DIR" describe --tags 2>/dev/null || git -C "$COMFYUI_DIR" rev-parse --short HEAD))"
    echo "   KHÔNG nên 'git pull' bừa — v0.32.0+ có regression chậm H3 (xem"
    echo "   ghi chú COMFYUI_REF ở đầu file). Muốn đổi version: cd $COMFYUI_DIR && git checkout <tag>"
  else
    step "Clone ComfyUI → $COMFYUI_DIR (pin $COMFYUI_REF)"
    git clone "$COMFYUI_GIT_URL" "$COMFYUI_DIR"
    git -C "$COMFYUI_DIR" checkout "$COMFYUI_REF"
  fi

  step "Cài dependencies ComfyUI ($PY)"
  "$PY" -m pip install -r "$COMFYUI_DIR/requirements.txt"
fi

# --- 2. Models H3 ------------------------------------------------------------
# Trỏ $COMFYUI_DIR/models vào $MODEL_ROOT (storage bền, vd Network Volume).
# Nếu MODEL_ROOT == $COMFYUI_DIR/models (mặc định) thì không làm gì cả.
if [ "$(readlink -f "$MODEL_ROOT" 2>/dev/null || echo "$MODEL_ROOT")" \
     != "$(readlink -f "$COMFYUI_DIR/models" 2>/dev/null || echo "$COMFYUI_DIR/models")" ]; then
  step "Link models → storage bền: $COMFYUI_DIR/models -> $MODEL_ROOT"
  mkdir -p "$MODEL_ROOT"
  if [ -L "$COMFYUI_DIR/models" ]; then
    rm -f "$COMFYUI_DIR/models"
  elif [ -d "$COMFYUI_DIR/models" ]; then
    echo "   ⚠ $COMFYUI_DIR/models đã tồn tại (không phải symlink)."
    echo "     Merge thủ công vào $MODEL_ROOT rồi xoá thư mục cũ, hoặc đổi MODEL_ROOT."
    exit 1
  fi
  ln -s "$MODEL_ROOT" "$COMFYUI_DIR/models"
fi

# Tải 1 file từ HF repo vào $COMFYUI_DIR/models/$subdir/<basename path>.
#
# QUAN TRỌNG: không gọi `hf download ... --local-dir "$COMFYUI_DIR/models/$subdir"`
# trực tiếp — khi $path đã có tiền tố thư mục (vd "vae/foo.safetensors"), hf
# download giữ nguyên cấu trúc đó bên trong --local-dir, tạo ra đường dẫn lồng
# trùng tên: models/vae/vae/foo.safetensors thay vì models/vae/foo.safetensors.
# Thay vào đó: tải vào thư mục tạm, rồi mv đúng 1 file ra đích tường minh.
dl_from() {
  local repo="$1" path="$2" subdir="$3" revision="${4:-}"
  local fname target tmp
  fname="$(basename "$path")"
  target="$COMFYUI_DIR/models/$subdir/$fname"
  if [ -f "$target" ] && [ -s "$target" ]; then
    printf '   ✓ có sẵn %s (%s)\n' "$target" "$(du -h "$target" | cut -f1)"
    return
  fi
  printf '   ↓ tải %s (từ %s%s)\n' "$path" "$repo" "${revision:+ @ ${revision:0:8}}"
  mkdir -p "$COMFYUI_DIR/models/$subdir"
  tmp="$(mktemp -d "$COMFYUI_DIR/models/.dl_tmp.XXXXXX")"
  if [ -n "$revision" ]; then
    hf download "$repo" "$path" --revision "$revision" --local-dir "$tmp"
  else
    hf download "$repo" "$path" --local-dir "$tmp"
  fi
  mv "$tmp/$path" "$target"
  rm -rf "$tmp"
}

# CLI `hf` mà dl_from() dùng đến từ huggingface_hub — phải cài TRƯỚC cả hai khối
# tải bên dưới, vì khối LoRA chạy trước khối models. `-U` là bắt buộc chứ không
# phải cho đẹp: `pip install <pkg>` bỏ qua hoàn toàn package đã cài sẵn, mà CLI
# `hf` chỉ có từ huggingface_hub >= 0.34 (bản cũ chỉ có `huggingface-cli`).
if [ "${SKIP_TURBO_LORA:-0}" != "1" ] || [ "${SKIP_MODELS:-0}" != "1" ]; then
  step "Cài huggingface_hub (cung cấp CLI 'hf')"
  "$PY" -m pip install -q -U "huggingface_hub>=0.34"
  if ! command -v hf >/dev/null 2>&1; then
    echo "   ⚠ Không thấy lệnh 'hf' trên PATH sau khi cài huggingface_hub."
    echo "     Thử: export PATH=\"\$($PY -c 'import site;print(site.USER_BASE)')/bin:\$PATH\""
    exit 1
  fi
  if [ -n "${HF_TOKEN:-}" ]; then
    export HF_TOKEN
    echo "   Dùng HF_TOKEN từ env (đã set)"
  else
    echo "   Lưu ý: chưa có HF_TOKEN. Nếu tải bị 401 (model gated) → chạy lại với HF_TOKEN=hf_xxx"
  fi
fi

if [ "${SKIP_TURBO_LORA:-0}" = "1" ]; then
  step "SKIP_TURBO_LORA=1 — bỏ qua tải Turbo LoRA"
else
  step "Tải H3 Turbo LoRA (~2.4GiB: REF2VA Larry v4-600 EMA pruned 0.58 + FL2VA LightX2V 8-step 1.82)"
  for entry in "${LORAS[@]}"; do
    IFS='|' read -r repo path subdir revision <<< "$entry"
    dl_from "$repo" "$path" "$subdir" "$revision"
  done
fi

if [ "${SKIP_MODELS:-0}" = "1" ]; then
  step "SKIP_MODELS=1 — bỏ qua tải models"
else
  step "Tải models H3 (~59GiB: 2 diffusion 19.53 mỗi cái + TE 14.61 + 2 VAE 5.41; skip file đã có)"
  for entry in "${MODELS[@]}"; do
    IFS='|' read -r repo path subdir revision <<< "$entry"
    dl_from "$repo" "$path" "$subdir" "$revision"
  done
fi

# --- 3. API venv --------------------------------------------------------------
if [ "${SKIP_API:-0}" = "1" ]; then
  step "SKIP_API=1 — bỏ qua venv API"
else
  step "Tạo venv + cài saniora (API)"
  cd "$REPO_DIR"
  [ -d .venv ] || "$PY" -m venv .venv
  # shellcheck disable=SC1091
  source .venv/bin/activate
  pip install -e ".[dev]"
fi

step "Xong. Tiếp theo:"
echo "  1) bash scripts/start.sh                     # launch ComfyUI (nếu chưa chạy) + API"
echo "  2) Kiểm tra: curl http://127.0.0.1:8000/health"
