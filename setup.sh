cat > fetch_models.sh <<'SCRIPT_EOF'
#!/usr/bin/env bash
# ============================================================================
# saniora — tải model H3 lên RunPod Network Volume (standalone, không cần repo)
#
# Chạy trên POD TẠM có gắn Network Volume (mount tại /workspace).
# Tải ~61.5 GiB / 66 GB → cần volume >= 80GB.
#
#   bash fetch_models.sh
#   DEST=/workspace/comfyui bash fetch_models.sh   # đổi đích nếu cần
#   SKIP_SPACE_CHECK=1 bash fetch_models.sh        # nếu df báo sai trên network mount
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

# Trừ đi phần đã tải xong (cho phép chạy lại khi volume gần đầy)
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

# --- 1. Cài huggingface_hub (CLI `hf`) ---------------------------------------
# -U là bắt buộc: `pip install <pkg>` bỏ qua hoàn toàn package đã cài sẵn,
# mà CLI `hf` chỉ có từ huggingface_hub >= 0.34 (bản cũ chỉ có `huggingface-cli`).
step "Cài huggingface_hub (CLI 'hf')"
"$PY" -m pip install -q -U "huggingface_hub>=0.34"
if ! command -v hf >/dev/null 2>&1; then
  export PATH="$("$PY" -c 'import site;print(site.USER_BASE)')/bin:$PATH"
fi
command -v hf >/dev/null 2>&1 || { echo "   ✗ Không thấy lệnh 'hf' trên PATH."; exit 1; }
echo "   hf: $(command -v hf)"

# --- 2. Tải ------------------------------------------------------------------
# Không gọi `hf download --local-dir "$DEST/models/$subdir"` trực tiếp: khi path
# đã có tiền tố thư mục (vd "vae/foo.safetensors"), hf giữ nguyên cấu trúc đó
# bên trong --local-dir → tạo ra models/vae/vae/foo.safetensors. Vì vậy: tải vào
# thư mục tạm rồi mv đúng 1 file ra đích (cùng filesystem nên mv là rename, tức thời).
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
  hf download "$repo" "$path" --revision "$rev" --local-dir "$tmp"
  mv "$tmp/$path" "$target"
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

cat <<EOF

✓ XONG — đủ ${#FILES[@]} file, tổng $(human "$need_bytes").

Cấu trúc trên volume giờ là:
  $DEST/models/{diffusion_models,text_encoders,vae,loras}/

Worker Serverless sẽ thấy đúng chỗ này dưới tên /runpod-volume/comfyui/models
(cùng volume, RunPod mount /workspace cho Pod và /runpod-volume cho Serverless),
khớp base_path trong extra_model_paths.yaml.

Tiếp theo: xoá pod tạm này (volume giữ nguyên data) → trỏ endpoint vào volume mới.
EOF
SCRIPT_EOF

bash fetch_models.sh
