PERS AUTOVIDEO - VPS

PASTAS
Entrada:
  /opt/pers-autovideo/input
  /root/PersAutoVideo-Entrada

Saida:
  /opt/pers-autovideo/output
  /root/PersAutoVideo-Saida

VIDEO DEMO
  /opt/pers-autovideo/output/projeto1-v2-final.mp4

N8N
  O n8n escuta somente em 127.0.0.1:5678.
  Acesse inicialmente por tunel SSH:

  ssh -L 5678:127.0.0.1:5678 root@SEU_IP_DA_VPS

  Depois abra:
  http://127.0.0.1:5678

WORKER
  Health:
  curl http://127.0.0.1:8787/health

  Render manual:
  TOKEN=$(cat /opt/pers-autovideo/.worker-token)
  curl -X POST http://127.0.0.1:8787/render \
    -H "Content-Type: application/json" \
    -H "X-Worker-Token: $TOKEN" \
    --data '{"project":"projeto1"}'

STATUS
  systemctl status pers-autovideo-worker --no-pager
  cd /opt/pers-autovideo/infra && docker compose ps

LOGS
  journalctl -u pers-autovideo-worker -f
  cd /opt/pers-autovideo/infra && docker compose logs -f n8n

IMPORTANTE
  As portas 5433, 5678 e 8787 estao presas ao localhost.
  Este instalador nao configura Nginx, Cloudflare ou UFW.
