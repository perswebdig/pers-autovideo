#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="${1:-projeto1}"

BASE="/opt/pers-autovideo"
INPUT="$BASE/input/$PROJECT"
OUTPUT="$BASE/output"
WORK="$BASE/data/render-v3-$PROJECT"

WHISPER="$BASE/tools/whisper.cpp/build/bin/whisper-cli"
MODEL="$BASE/tools/whisper.cpp/models/ggml-base.bin"

WIDTH=1080
HEIGHT=1920
FPS=30
TRANSITION=0.50
DEFAULT_SCENE_DURATION="${PERS_DEFAULT_SCENE_DURATION:-4.0}"
THREADS="${PERS_RENDER_THREADS:-2}"

mkdir -p "$OUTPUT"
rm -rf "$WORK"
mkdir -p "$WORK/segments" "$WORK/ordered"

echo "================================================="
echo " PERS AUTOVIDEO V3"
echo " Projeto: $PROJECT"
echo "================================================="

if [ ! -d "$INPUT" ]; then
    echo "ERRO: projeto nao encontrado: $INPUT"
    exit 1
fi

# Audio e totalmente opcional.
NARRATION="$(find "$INPUT" -maxdepth 1 -type f \
    \( -iname 'narracao.mp3' -o -iname 'narracao.wav' -o -iname 'narracao.m4a' \
       -o -iname 'narration.mp3' -o -iname 'narration.wav' -o -iname 'narration.m4a' \) \
    -print -quit || true)"

MUSIC="$(find "$INPUT" -maxdepth 1 -type f \
    \( -iname 'musica.mp3' -o -iname 'musica.wav' -o -iname 'musica.m4a' \
       -o -iname 'music.mp3' -o -iname 'music.wav' -o -iname 'music.m4a' \) \
    -print -quit || true)"

# Ordenacao natural e deterministica. Nao renomeia nem altera os originais.
# O sistema cria uma numeracao interna (001, 002, 003...) dentro do WORK.
python3 - "$INPUT" "$WORK" <<'PY'
from pathlib import Path
import re
import sys

src = Path(sys.argv[1])
work = Path(sys.argv[2])
ordered = work / "ordered"

allowed = {".jpg", ".jpeg", ".png", ".webp", ".mp4", ".mov", ".webm"}

files = [p for p in src.iterdir() if p.is_file() and p.suffix.lower() in allowed]

def natural_key(path):
    name = path.name.casefold()
    return [int(part) if part.isdigit() else part
            for part in re.split(r"(\d+)", name)]

files.sort(key=natural_key)

manifest = work / "ordem-midias.tsv"
with manifest.open("w", encoding="utf-8") as fh:
    fh.write("ordem\tarquivo_original\tarquivo_interno\n")
    for idx, path in enumerate(files, 1):
        internal = f"{idx:03d}{path.suffix.lower()}"
        target = ordered / internal
        target.symlink_to(path.resolve())
        fh.write(f"{idx:03d}\t{path.name}\t{internal}\n")

if not files:
    raise SystemExit(3)
PY

if [ "$?" -eq 3 ]; then
    echo "ERRO: nenhuma imagem ou video encontrado."
    exit 1
fi

mapfile -d '' ASSETS < <(
    find "$WORK/ordered" -maxdepth 1 -type l -print0 | sort -z
)

COUNT="${#ASSETS[@]}"

if [ "$COUNT" -eq 0 ]; then
    echo "ERRO: nenhuma imagem ou video encontrado."
    exit 1
fi

echo
echo "Ordem criada automaticamente:"
column -t -s $'\t' "$WORK/ordem-midias.tsv" 2>/dev/null || cat "$WORK/ordem-midias.tsv"

if [ -n "$NARRATION" ]; then
    DURATION="$(ffprobe \
        -v error \
        -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 \
        "$NARRATION")"

    SCENE_DURATION="$(python3 - <<PY
duration=float("$DURATION")
count=int("$COUNT")
transition=float("$TRANSITION")
scene = duration if count == 1 else (duration + ((count-1)*transition))/count
print(f"{max(scene, transition + 0.25):.4f}")
PY
)"
    echo
    echo "Narracao: $(basename "$NARRATION")"
    echo "Duracao da narracao: ${DURATION}s"
else
    DURATION=""
    SCENE_DURATION="$DEFAULT_SCENE_DURATION"
    echo
    echo "Narracao: nao informada"
fi

if [ -n "$MUSIC" ]; then
    echo "Musica: $(basename "$MUSIC")"
else
    echo "Musica: nao informada"
fi

echo "Midias: $COUNT"
echo "Duracao por cena: ${SCENE_DURATION}s"

FRAMES="$(python3 - <<PY
import math
print(max(1, math.ceil(float("$SCENE_DURATION") * int("$FPS"))))
PY
)"

INDEX=0

for FILE in "${ASSETS[@]}"; do
    INDEX=$((INDEX + 1))
    EXT="${FILE##*.}"
    EXT="${EXT,,}"
    SEGMENT="$(printf '%s/segments/%03d.mp4' "$WORK" "$INDEX")"
    EFFECT=$(( (INDEX - 1) % 4 ))

    ORIGINAL="$(readlink -f "$FILE")"

    echo
    echo "Cena $INDEX/$COUNT: $(basename "$ORIGINAL")"

    case "$EXT" in
        jpg|jpeg|png|webp)
            case "$EFFECT" in
                0)
                    MOTION="zoompan=z='min(zoom+0.0008,1.09)':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=1:s=${WIDTH}x${HEIGHT}:fps=${FPS}"
                    echo "Movimento: Zoom In"
                ;;
                1)
                    MOTION="zoompan=z='if(eq(on,0),1.09,max(1.0,zoom-0.0008))':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=1:s=${WIDTH}x${HEIGHT}:fps=${FPS}"
                    echo "Movimento: Zoom Out"
                ;;
                2)
                    MOTION="zoompan=z='1.08':x='(iw-iw/zoom)*on/${FRAMES}':y='ih/2-(ih/zoom/2)':d=1:s=${WIDTH}x${HEIGHT}:fps=${FPS}"
                    echo "Movimento: Pan esquerda para direita"
                ;;
                3)
                    MOTION="zoompan=z='1.08':x='(iw-iw/zoom)*(1-on/${FRAMES})':y='ih/2-(ih/zoom/2)':d=1:s=${WIDTH}x${HEIGHT}:fps=${FPS}"
                    echo "Movimento: Pan direita para esquerda"
                ;;
            esac

            ffmpeg -hide_banner -loglevel warning -y \
                -loop 1 \
                -framerate "$FPS" \
                -i "$ORIGINAL" \
                -t "$SCENE_DURATION" \
                -vf "scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=increase,crop=${WIDTH}:${HEIGHT},${MOTION},format=yuv420p" \
                -an \
                -c:v libx264 \
                -preset veryfast \
                -crf 20 \
                -threads "$THREADS" \
                -r "$FPS" \
                "$SEGMENT"
        ;;

        mp4|mov|webm)
            echo "Movimento: video original"

            ffmpeg -hide_banner -loglevel warning -y \
                -i "$ORIGINAL" \
                -vf "scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=increase,crop=${WIDTH}:${HEIGHT},fps=${FPS},tpad=stop_mode=clone:stop_duration=3600,trim=duration=${SCENE_DURATION},setpts=PTS-STARTPTS,format=yuv420p" \
                -an \
                -c:v libx264 \
                -preset veryfast \
                -crf 20 \
                -threads "$THREADS" \
                -r "$FPS" \
                "$SEGMENT"
        ;;
    esac
done

echo
echo "=== CRIANDO TRANSICOES ==="

if [ "$COUNT" -eq 1 ]; then
    cp "$WORK/segments/001.mp4" "$WORK/video-transicoes.mp4"
else
    INPUT_ARGS=()
    for SEGMENT in "$WORK"/segments/*.mp4; do
        INPUT_ARGS+=(-i "$SEGMENT")
    done

    FILTER=""
    PREVIOUS="[0:v]"

    for ((i=1; i<COUNT; i++)); do
        OFFSET="$(python3 - <<PY
i=$i
scene=float("$SCENE_DURATION")
transition=float("$TRANSITION")
print(f"{i*(scene-transition):.4f}")
PY
)"
        OUT="[x${i}]"
        if (( i % 2 == 0 )); then TYPE="dissolve"; else TYPE="fade"; fi
        FILTER+="${PREVIOUS}[${i}:v]xfade=transition=${TYPE}:duration=${TRANSITION}:offset=${OFFSET}${OUT};"
        PREVIOUS="$OUT"
    done

    FILTER="${FILTER%;}"

    ffmpeg -hide_banner -loglevel warning -y \
        "${INPUT_ARGS[@]}" \
        -filter_complex "$FILTER" \
        -map "$PREVIOUS" \
        -an \
        -c:v libx264 \
        -preset veryfast \
        -crf 20 \
        -threads "$THREADS" \
        -pix_fmt yuv420p \
        "$WORK/video-transicoes.mp4"
fi

SRT=""

if [ -n "$NARRATION" ]; then
    echo
    echo "=== GERANDO LEGENDAS ==="

    if [ -x "$WHISPER" ] && [ -f "$MODEL" ]; then
        ffmpeg -hide_banner -loglevel warning -y \
            -i "$NARRATION" \
            -ar 16000 \
            -ac 1 \
            -c:a pcm_s16le \
            "$WORK/narracao-16k.wav"

        "$WHISPER" \
            -m "$MODEL" \
            -f "$WORK/narracao-16k.wav" \
            -l pt \
            -t "$THREADS" \
            -osrt \
            -sow \
            -ml 38 \
            -of "$WORK/legendas"

        if [ -s "$WORK/legendas.srt" ]; then
            SRT="$WORK/legendas.srt"
        else
            echo "AVISO: Whisper nao gerou legenda. Continuando sem legenda."
        fi
    else
        echo "AVISO: Whisper indisponivel. Continuando sem legenda."
    fi
else
    echo
    echo "Sem narracao: etapa de legendas ignorada."
fi

echo
echo "=== AUDIO ==="

AUDIO_VIDEO="$WORK/video-audio.mp4"

if [ -n "$NARRATION" ] && [ -n "$MUSIC" ]; then
    echo "Modo: narracao + musica com ducking"

    ffmpeg -hide_banner -loglevel warning -y \
        -i "$WORK/video-transicoes.mp4" \
        -i "$NARRATION" \
        -stream_loop -1 \
        -i "$MUSIC" \
        -filter_complex "
        [1:a]volume=1.0,aformat=sample_rates=48000:channel_layouts=stereo[narr];
        [2:a]volume=0.22,aformat=sample_rates=48000:channel_layouts=stereo[music];
        [music][narr]sidechaincompress=threshold=0.025:ratio=8:attack=20:release=350[ducked];
        [narr][ducked]amix=inputs=2:duration=first:normalize=0,alimiter=limit=0.95[audio]
        " \
        -map 0:v \
        -map "[audio]" \
        -c:v copy \
        -c:a aac \
        -b:a 160k \
        -shortest \
        "$AUDIO_VIDEO"

elif [ -n "$NARRATION" ]; then
    echo "Modo: somente narracao"

    ffmpeg -hide_banner -loglevel warning -y \
        -i "$WORK/video-transicoes.mp4" \
        -i "$NARRATION" \
        -map 0:v \
        -map 1:a \
        -c:v copy \
        -c:a aac \
        -b:a 160k \
        -shortest \
        "$AUDIO_VIDEO"

elif [ -n "$MUSIC" ]; then
    echo "Modo: somente musica"

    ffmpeg -hide_banner -loglevel warning -y \
        -i "$WORK/video-transicoes.mp4" \
        -stream_loop -1 \
        -i "$MUSIC" \
        -filter_complex "[1:a]volume=0.28,alimiter=limit=0.95[audio]" \
        -map 0:v \
        -map "[audio]" \
        -c:v copy \
        -c:a aac \
        -b:a 160k \
        -shortest \
        "$AUDIO_VIDEO"

else
    echo "Modo: sem audio"
    cp "$WORK/video-transicoes.mp4" "$AUDIO_VIDEO"
fi

FINAL="$OUTPUT/${PROJECT}-v3-final.mp4"

echo
echo "=== FINALIZANDO ==="

if [ -n "$SRT" ]; then
    ffmpeg -hide_banner -loglevel warning -y \
        -i "$AUDIO_VIDEO" \
        -vf "subtitles='$SRT':force_style='FontName=DejaVu Sans,FontSize=26,Bold=1,PrimaryColour=&H00FFFFFF,OutlineColour=&H00000000,BorderStyle=1,Outline=3,Shadow=1,Alignment=2,MarginV=170'" \
        -c:v libx264 \
        -preset medium \
        -crf 19 \
        -threads "$THREADS" \
        -c:a copy \
        -movflags +faststart \
        "$FINAL"
else
    ffmpeg -hide_banner -loglevel warning -y \
        -i "$AUDIO_VIDEO" \
        -c copy \
        -movflags +faststart \
        "$FINAL"
fi

echo
echo "================================================="
echo " VIDEO CONCLUIDO"
echo " $FINAL"
echo "================================================="

ffprobe \
    -v error \
    -show_entries format=duration,size \
    -show_entries stream=codec_name,width,height,r_frame_rate \
    -of default=noprint_wrappers=1 \
    "$FINAL"
