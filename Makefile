PREFIX  ?= /usr/local
DESTDIR ?=
SBINDIR  = $(PREFIX)/sbin
DOCDIR   = $(PREFIX)/share/doc/btrfs-auto-snapshot
UNITDIR ?= /etc/systemd/system
LABELS   = frequent hourly daily weekly monthly

.PHONY: all install install-systemd install-cron uninstall test

all:

install:
	install -D -m 0755 src/btrfs-auto-snapshot $(DESTDIR)$(SBINDIR)/btrfs-auto-snapshot
	install -D -m 0644 README.md $(DESTDIR)$(DOCDIR)/README.md
	[ -e $(DESTDIR)/etc/default/btrfs-auto-snapshot ] || \
		install -D -m 0644 etc/btrfs-auto-snapshot.default $(DESTDIR)/etc/default/btrfs-auto-snapshot

install-systemd: install
	install -D -m 0644 systemd/btrfs-auto-snapshot@.service $(DESTDIR)$(UNITDIR)/btrfs-auto-snapshot@.service
	sed -i 's|/usr/local/sbin|$(SBINDIR)|' $(DESTDIR)$(UNITDIR)/btrfs-auto-snapshot@.service
	for l in $(LABELS); do \
		install -m 0644 systemd/btrfs-auto-snapshot-$$l.timer $(DESTDIR)$(UNITDIR)/; \
	done
	@echo "Enable with: systemctl daemon-reload && systemctl enable --now btrfs-auto-snapshot-{frequent,hourly,daily,weekly,monthly}.timer"

install-cron: install
	install -D -m 0644 etc/btrfs-auto-snapshot.cron $(DESTDIR)/etc/cron.d/btrfs-auto-snapshot

uninstall:
	-for l in $(LABELS); do systemctl disable --now btrfs-auto-snapshot-$$l.timer 2>/dev/null; done
	rm -f $(DESTDIR)$(SBINDIR)/btrfs-auto-snapshot
	rm -rf $(DESTDIR)$(DOCDIR)
	rm -f $(DESTDIR)$(UNITDIR)/btrfs-auto-snapshot@.service
	for l in $(LABELS); do rm -f $(DESTDIR)$(UNITDIR)/btrfs-auto-snapshot-$$l.timer; done
	rm -f $(DESTDIR)/etc/cron.d/btrfs-auto-snapshot

test:
	bash -n src/btrfs-auto-snapshot
	tests/run-tests.sh
