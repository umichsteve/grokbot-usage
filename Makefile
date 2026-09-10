.PHONY: generate open build clean session-dir

generate:
	xcodegen generate

open: generate
	open GrokBotUsage.xcodeproj

build:
	swift build -c release

clean:
	rm -rf .build GrokBotUsage.xcodeproj DerivedData

session-dir:
	@echo "Preferred: grok login  →  ~/.grok/auth.json"
	mkdir -p $(HOME)/.config/grokbot-usage
	chmod 700 $(HOME)/.config/grokbot-usage
	@if [ ! -f $(HOME)/.config/grokbot-usage/session ]; then \
		cp session.example $(HOME)/.config/grokbot-usage/session; \
		chmod 600 $(HOME)/.config/grokbot-usage/session; \
		echo "Created advanced fallback ~/.config/grokbot-usage/session — edit locally only if needed."; \
	else \
		echo "~/.config/grokbot-usage/session already exists"; \
	fi
