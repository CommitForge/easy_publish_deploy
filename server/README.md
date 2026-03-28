chmod 700 /root/izipublish/cron/izipublish_sync.sh

systemctl daemon-reload
systemctl restart izipublish_sync.timer
