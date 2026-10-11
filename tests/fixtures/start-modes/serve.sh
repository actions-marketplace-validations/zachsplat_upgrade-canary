echo "starting"
sleep 2
mkdir -p /www
echo ok > /www/health
echo "listening on 8080"
exec httpd -f -p 8080 -h /www
