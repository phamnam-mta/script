#!/usr/bin/env bash
# ============================================================================
# saniora — tải model H3 lên RunPod Network Volume (standalone, không cần repo)
#
#   bash fetch_models.sh
#   DEST=/workspace/comfyui bash fetch_models.sh   # đổi đích nếu cần
#   SKIP_SPACE_CHECK=1 bash fetch_models.sh        # nếu df báo sai trên network mount
#   PY=python3.13 bash fetch_models.sh             # ép dùng python cụ thể
#
# Chạy lại được nhiều lần: file nào đủ dung lượng thì bỏ qua, thiếu/cụt thì tải lại.
# ============================================================================
set -euo pipefail

DEST="${DEST:-/workspace/comfyui}"
PY="${PY:-python3}"

# repo | đường dẫn trong repo | thư mục đích | commit SHA (pin) | dung lượng byte
FILES=(
  "drbaph/MiniMax-H3-Turbo-Lora-ComfyUI|minimax_h3_turbo_v4_step600_ema_pruned_comfyui.safetensors|loras|4728c77ec8c0a32b9ec62a128f6c118372f5fa1f|620285592"
  "lightx2v/Minimax-h3-Turbo|minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors|loras|ec01fa4c86263832faa0bd1d6d8f36a281eaabb2|1956193000"
  "Comfy-Org/MiniMax-H3|diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors|diffusion_models|6701b0a14feefd7141bd9cfe8386961c27007622|20970379616"
  "Comfy-Org/MiniMax-H3|diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors|diffusion_models|6701b0a14feefd7141bd9cfe8386961c27007622|20970379616"
  "Comfy-Org/MiniMax-H3|text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors|text_encoders|6701b0a14feefd7141bd9cfe8386961c27007622|15687142551"
  "Comfy-Org/MiniMax-H3|vae/minimax_h3_video_vae_fp16.safetensors|vae|6701b0a14feefd7141bd9cfe8386961c27007622|5207808496"
  "Comfy-Org/MiniMax-H3|vae/minimax_h3_audio_vae_fp32.safetensors|vae|6701b0a14feefd7141bd9cfe8386961c27007622|605254808"
)

need_bytes=0
for e in "${FILES[@]}"; do
  need_bytes=$(( need_bytes + $(cut -d'|' -f5 <<<"$e") ))
done

step() { printf '\n==> %s\n' "$1"; }
human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1 bytes"; }

# --- 0. Kiểm tra volume + dung lượng trống -----------------------------------
step "Kiểm tra đích: $DEST"
vol_root="$(df -P "$(dirname "$DEST")" 2>/dev/null | awk 'NR==2{print $6}')" || true
if [ -z "${vol_root:-}" ]; then
  echo "   ⚠ Không đọc được filesystem của $(dirname "$DEST") — volume đã mount chưa?"
  exit 1
fi
avail_kb="$(df -P "$(dirname "$DEST")" | awk 'NR==2{print $4}')"
avail_bytes=$(( avail_kb * 1024 ))
echo "   filesystem : $vol_root"
echo "   cần        : $(human "$need_bytes")"
echo "   còn trống  : $(human "$avail_bytes")"

have_bytes=0
for e in "${FILES[@]}"; do
  IFS='|' read -r _ path subdir _ size <<<"$e"
  f="$DEST/models/$subdir/$(basename "$path")"
  if [ -f "$f" ] && [ "$(stat -c%s "$f" 2>/dev/null || echo 0)" = "$size" ]; then
    have_bytes=$(( have_bytes + size ))
  fi
done
still=$(( need_bytes - have_bytes ))
if [ "${SKIP_SPACE_CHECK:-0}" = "1" ]; then
  echo "   (SKIP_SPACE_CHECK=1 — bỏ qua kiểm tra dung lượng)"
elif [ "$still" -gt 0 ] && [ "$avail_bytes" -lt "$still" ]; then
  echo
  echo "   ✗ KHÔNG ĐỦ CHỖ. Còn phải tải $(human "$still") nhưng chỉ trống $(human "$avail_bytes")."
  echo "     Volume cần >= 80GB (RunPod bán theo GB thập phân: 60GB thật ra chỉ ~55.9 GiB)."
  exit 1
fi

# --- 1. Tìm Python có huggingface_hub ----------------------------------------
# Image RunPod thường có NHIỀU python: /usr/bin/python3 trần (không có pip) và
# một bản khác (vd python3.13 ở /usr/local) chứa site-packages thật. Nên:
#  1) tìm interpreter nào import được huggingface_hub → dùng luôn, khỏi cài;
#  2) chỉ khi không có mới đi cài, qua trình pip nào thực sự chạy được.
# Dùng Python API (hf_hub_download) thay cho CLI `hf` → không phụ thuộc PATH.
step "Tìm Python có huggingface_hub"
PYBIN=""
for cand in "$PY" python3 python3.13 python3.12 python3.11 python; do
  command -v "$cand" >/dev/null 2>&1 || continue
  if "$cand" -c "import huggingface_hub" >/dev/null 2>&1; then PYBIN="$cand"; break; fi
done

if [ -z "$PYBIN" ]; then
  echo "   chưa có huggingface_hub — thử cài"
  installed=0
  for cand in "$PY -m pip" python3.13\ -m\ pip pip3 pip "python3 -m pip"; do
    $cand --version >/dev/null 2>&1 || continue
    echo "   dùng: $cand"
    $cand install -q -U "huggingface_hub>=0.34" && installed=1 && break
  done
  [ "$installed" = 1 ] || { echo "   ✗ Không cài được huggingface_hub. Thử tay: pip install -U huggingface_hub"; exit 1; }
  for cand in "$PY" python3 python3.13 python3.12 python3.11 python; do
    command -v "$cand" >/dev/null 2>&1 || continue
    if "$cand" -c "import huggingface_hub" >/dev/null 2>&1; then PYBIN="$cand"; break; fi
  done
fi
[ -n "$PYBIN" ] || { echo "   ✗ Cài xong vẫn không import được huggingface_hub."; exit 1; }
echo "   python : $(command -v "$PYBIN")"
echo "   version: $("$PYBIN" -c 'import huggingface_hub as h;print(h.__version__)')"

# --- 2. Tải ------------------------------------------------------------------
# Tải vào thư mục tạm rồi mv ra đích. hf_hub_download giữ nguyên cấu trúc thư mục
# của `path` bên trong local_dir (vd vae/foo.safetensors), nên KHÔNG trỏ thẳng vào
# đích được — nhưng nó trả về đường dẫn thật, khỏi phải đoán. mv cùng filesystem
# là rename, tức thời, không tốn thêm chỗ.
tmp=""
cleanup() { [ -n "$tmp" ] && [ -d "$tmp" ] && rm -rf "$tmp"; }
trap cleanup EXIT INT TERM

i=0
for e in "${FILES[@]}"; do
  i=$(( i + 1 ))
  IFS='|' read -r repo path subdir rev size <<<"$e"
  fname="$(basename "$path")"
  target="$DEST/models/$subdir/$fname"

  if [ -f "$target" ]; then
    actual="$(stat -c%s "$target" 2>/dev/null || echo 0)"
    if [ "$actual" = "$size" ]; then
      printf '\n[%d/%d] ✓ có sẵn, đúng dung lượng: %s\n' "$i" "${#FILES[@]}" "$fname"
      continue
    fi
    printf '\n[%d/%d] ⚠ %s có nhưng SAI dung lượng (%s ≠ %s) — tải lại\n' \
      "$i" "${#FILES[@]}" "$fname" "$actual" "$size"
    rm -f "$target"
  fi

  printf '\n[%d/%d] ↓ %s  (%s, từ %s @ %s)\n' \
    "$i" "${#FILES[@]}" "$fname" "$(human "$size")" "$repo" "${rev:0:8}"
  mkdir -p "$DEST/models/$subdir"
  tmp="$(mktemp -d "$DEST/models/.dl_tmp.XXXXXX")"
  got="$("$PYBIN" - "$repo" "$path" "$rev" "$tmp" <<'PYDL'
import sys
from huggingface_hub import hf_hub_download
repo, path, rev, dest = sys.argv[1:5]
print(hf_hub_download(repo_id=repo, filename=path, revision=rev, local_dir=dest))
PYDL
)"
  [ -f "$got" ] || { echo "   ✗ Không thấy file sau khi tải: $got"; exit 1; }
  mv "$got" "$target"
  rm -rf "$tmp"; tmp=""
done

# --- 3. Verify ---------------------------------------------------------------
step "Kiểm tra kết quả"
fail=0
for e in "${FILES[@]}"; do
  IFS='|' read -r _ path subdir _ size <<<"$e"
  fname="$(basename "$path")"
  target="$DEST/models/$subdir/$fname"
  actual="$(stat -c%s "$target" 2>/dev/null || echo 0)"
  if [ "$actual" = "$size" ]; then
    printf '   ✓ %-18s %-56s %s\n' "$subdir" "$fname" "$(human "$size")"
  else
    printf '   ✗ %-18s %-56s có %s, cần %s\n' "$subdir" "$fname" "$actual" "$size"
    fail=1
  fi
done

echo
du -sh "$DEST"/models/* 2>/dev/null || true
echo
df -h "$vol_root" | awk 'NR==1||NR==2'

if [ "$fail" = 1 ]; then
  echo
  echo "✗ Có file chưa đúng — chạy lại script (nó sẽ chỉ tải phần thiếu)."
  exit 1
fi
