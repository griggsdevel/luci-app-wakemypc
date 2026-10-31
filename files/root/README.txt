WakeMyPc установлен.

Web UI:  http://<router-ip>/cgi-bin/luci/admin/services/wakemypc
Логи:    logread | grep wakemypc
Старт:   /etc/init.d/wakemypc start
Стоп:    /etc/init.d/wakemypc stop
Язык:    uci set wakemypc.bot.lang='ru'   (auto|ru|en)
Обновить: wget -qO- https://raw.githubusercontent.com/griggsdevel/luci-app-wakemypc/main/update.sh | sh
Удалить: wget -qO- https://raw.githubusercontent.com/griggsdevel/luci-app-wakemypc/main/uninstall.sh | sh

Перед первым запуском заполни токен и данные ПК в LuCI.
Конфиг: /etc/config/wakemypc   (uci get wakemypc.bot.token)
