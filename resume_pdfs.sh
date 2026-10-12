#!/usr/bin/env bash
# 续传轮：只处理"还没有成品 pdf"的条目，靠 -C - 断点续传。
# 无体积探测阶段（太慢），直接并发拉；可反复执行，已完成的自动跳过。
# 用法: bash resume_pdfs.sh [jobs] [seconds]   例: bash resume_pdfs.sh 8 480
# 模式来源：3D24D_paper 仓库（并发 6-12 + 断点续传；arXiv 单连接仅 18-47KB/s）
cd "$(dirname "$0")" || exit 1
mkdir -p papers
JOBS="${1:-8}"
BUDGET="${2:-480}"
DEADLINE=$(( $(date +%s) + BUDGET ))
IDS() { grep -E '^[0-9]{4}\.[0-9]{4,5}' all_arxiv_ids.txt; }
TOTAL=$(IDS | wc -l)

one() {
  id="$1"
  out="papers/${id}.pdf"
  [ -s "$out" ] && { echo "SKIP $id"; return 0; }
  part="${out}.part"
  before=$(stat -c %s "$part" 2>/dev/null || echo 0)
  curl -sS -L -C - --connect-timeout 15 --max-time 200 \
       -A "Mozilla/5.0 (compatible; paper-archiver)" -o "$part" \
       "https://arxiv.org/pdf/${id}" >/dev/null 2>&1
  after=$(stat -c %s "$part" 2>/dev/null || echo 0)
  if [ "$after" -gt 50000 ] && head -c 5 "$part" 2>/dev/null | grep -q '%PDF'; then
    # 完整判据：末尾含 PDF 结束标记
    if tail -c 2048 "$part" 2>/dev/null | grep -qa 'EOF'; then
      mv "$part" "$out"; echo "OK   $id  $((after/1024))KB"; return 0
    fi
    echo "PART $id  $((before/1024))->$((after/1024))KB"
  else
    echo "WAIT $id  $((after/1024))KB"
  fi
  return 1
}
export -f one

round=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  round=$((round+1))
  : > /tmp/todo.txt
  while read -r id; do [ -s "papers/${id}.pdf" ] || echo "$id" >> /tmp/todo.txt; done < <(IDS)
  n=$(wc -l < /tmp/todo.txt)
  if [ "$n" -eq 0 ]; then echo "*** 全部完成 ***"; break; fi
  echo "=== 第 $round 轮 | 待下载 $n | 剩余 $(( DEADLINE - $(date +%s) ))s ==="
  xargs -P "$JOBS" -I{} bash -c 'one "$@"' _ {} < /tmp/todo.txt 2>/dev/null \
    | awk '{c[$1]++} END{for(k in c) printf "  %s x%d\n", k, c[k]}'
  echo "  已完成: $(ls papers/*.pdf 2>/dev/null | wc -l)/${TOTAL}"
done

echo "=== 结束: $(ls papers/*.pdf 2>/dev/null | wc -l)/${TOTAL} ==="
n=0; while read -r id; do [ -s "papers/${id}.pdf" ] || { n=$((n+1)); printf "  待续 %s (%sKB)\n" "$id" "$(( $(stat -c %s papers/${id}.pdf.part 2>/dev/null || echo 0)/1024 ))"; }; done < <(IDS)
[ "$n" -eq 0 ] && echo "  无待续项 —— 全部下完"
