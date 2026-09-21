# Pers AutoVideo

Sistema de automação para geração de vídeos a partir de imagens, vídeos,
narração e música.

## Arquitetura

- Worker Python com API HTTP
- Renderização com FFmpeg
- Ordenação automática de mídias
- Narração opcional
- Música opcional
- Ducking automático entre narração e música
- Geração opcional de legendas com Whisper
- Fila automática de projetos
- Status persistente dos jobs

## Estrutura

```text
worker/
  worker-api.py
  render-auto-v2.sh

input/
  projetos de entrada

output/
  vídeos renderizados

data/
  estados e arquivos temporários

main
