#!/usr/bin/env bash
# Regenerate list-chime.wav: a lorem ipsum list read aloud, each item marked by an
# unobtrusive chime. Usage: ./make_demo.sh [bell|pluck|soft] [CHIME_DBFS] [VOICE_ONNX]
set -euo pipefail
cd "$(dirname "$0")"

STYLE="${1:-bell}"                    # bell | pluck | soft
LEVEL="${2--20}"                      # chime peak in dBFS; less negative = more audible
MODEL="${3:-/usr/share/piper-voices/en/en_GB/alan/medium/en_GB-alan-medium.onnx}"
SPEED=0.7

case "$STYLE" in
  bell)   # two partials, C6 over G6, fast decay - a soft desk bell
    sox -n -r 22050 -c 1 p1.wav synth 0.32 sine 1046.5 fade t 0.003 0.32 0.31 gain -3
    sox -n -r 22050 -c 1 p2.wav synth 0.22 sine 1568.0 fade t 0.003 0.22 0.21 gain -12
    sox -m p1.wav p2.wav chime.wav gain -n "$LEVEL"
    rm -f p1.wav p2.wav ;;
  pluck)  # woodier, shorter sustain
    sox -n -r 22050 -c 1 chime.wav synth 0.35 pluck C6 fade t 0.002 0.35 0.30 gain -n "$LEVEL" ;;
  soft)   # single sine, lowest and most neutral
    sox -n -r 22050 -c 1 chime.wav synth 0.28 sine 880 fade h 0.004 0.28 0.26 gain -n "$LEVEL" ;;
  *) echo "unknown style: $STYLE (bell|pluck|soft)" >&2; exit 1 ;;
esac
sox chime.wav chime_gap.wav pad 0 0.12  # air between chime and speech

# Punctuate the list with dictate's own preprocessor, one item per line
source <(sed -n '/^expand_markup()/,/^}/p' ../dictate)
expand_markup < list.md \
  | sed -E 's/<!--.*-->//g; s#</?[a-zA-Z][^>]*>##g' \
  | sed -E 's/\[([^]]*)\]\([^)]*\)/\1/g
            s/^[[:space:]]*#+[[:space:]]*//
            s/^[[:space:]]*>+[[:space:]]*//
            s/[*`|]//g; s/_/ /g' \
  | grep -v '^[[:space:]]*$' > lines.txt

n=0
while IFS= read -r line; do
  n=$((n+1)); s=$(printf '%02d' $n)
  printf '%s\n' "$line" | piper-tts -q -m "$MODEL" --length_scale "$SPEED" -f "raw_$n.wav" >/dev/null 2>&1
  if [ "$n" -eq 1 ]; then
    sox "raw_$n.wav" "seg_$s.wav" pad 0 0.5     # lead-in line, no tick
  else
    sox chime_gap.wav "raw_$n.wav" "seg_$s.wav" pad 0 0.4
  fi
done < lines.txt

# shellcheck disable=SC2046
sox $(ls seg_*.wav | sort) list-chime.wav
rm -f raw_*.wav seg_*.wav chime_gap.wav
printf 'list-chime.wav  %s  %s chime at %s dBFS\n' "$(soxi -d list-chime.wav)" "$STYLE" "$LEVEL"
