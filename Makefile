#
# Copyright (c) 2026 WakeMyPc contributors
#
# This is free software, licensed under the MIT License.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-wakemypc
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=griggsdevel

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-wakemypc
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=WakeMyPc - Telegram control for home PC
  DEPENDS:=+luci-base +curl +jq +etherwake +openssh-client
  PKGARCH:=all
endef

define Package/luci-app-wakemypc/description
  Telegram bot that powers a home PC on via Wake-on-LAN and shuts it down
  or reboots it over SSH. Includes a LuCI web interface (RU/EN).
endef

define Package/luci-app-wakemypc/conffiles
/etc/config/wakemypc
endef

define Build/Compile
endef

define Package/luci-app-wakemypc/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/wakemypc

	$(CP) ./files/* $(1)/

	$(INSTALL_BIN) $(1)/usr/bin/wakemypc
	$(INSTALL_BIN) $(1)/etc/init.d/wakemypc
endef

define Package/luci-app-wakemypc/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/wakemypc enable >/dev/null 2>&1
	rm -f /tmp/luci-indexcache* 2>/dev/null
	rm -rf /tmp/luci-modulecache 2>/dev/null
}
exit 0
endef

define Package/luci-app-wakemypc/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache* 2>/dev/null
	rm -rf /tmp/luci-modulecache 2>/dev/null
}
exit 0
endef

$(eval $(call BuildPackage,luci-app-wakemypc))
