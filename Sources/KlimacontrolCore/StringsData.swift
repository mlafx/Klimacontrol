// Erzeugt von tools/sync_strings.py aus l10n/Localizable.xcstrings – nicht von Hand ändern.

extension StringsData {
    static let catalog = #"""
{
  "sourceLanguage" : "en",
  "strings" : {
    "bridge.formatInvalid" : {
      "comment" : "Windows: kc_set_locale mit unvollständigem Format",
      "extractionState" : "manual",
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Die Formateinstellung von Windows ist unvollständig. Zahlen und Uhrzeiten erscheinen im deutschen Format. (bad-format)"
          }
        },
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "The Windows format settings are incomplete. Numbers and times appear in German format. (bad-format)"
          }
        }
      }
    },
    "bridge.localeUnreadable" : {
      "comment" : "Windows: kc_set_locale mit unlesbarem JSON",
      "extractionState" : "manual",
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Die Sprach- und Formateinstellung ist nicht lesbar. Bitte die App neu starten. (bad-locale)"
          }
        },
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "The language and format settings could not be read. Please restart the app. (bad-locale)"
          }
        }
      }
    },
    "common.minutes" : {
      "comment" : "Dauer in Minuten (Timer-Auswahl)",
      "extractionState" : "manual",
      "localizations" : {
        "de" : {
          "variations" : {
            "plural" : {
              "one" : {
                "stringUnit" : {
                  "state" : "translated",
                  "value" : "{count} Minute"
                }
              },
              "other" : {
                "stringUnit" : {
                  "state" : "translated",
                  "value" : "{count} Minuten"
                }
              }
            }
          }
        },
        "en" : {
          "variations" : {
            "plural" : {
              "one" : {
                "stringUnit" : {
                  "state" : "translated",
                  "value" : "{count} minute"
                }
              },
              "other" : {
                "stringUnit" : {
                  "state" : "translated",
                  "value" : "{count} minutes"
                }
              }
            }
          }
        }
      }
    },
    "settings.currency.invalid" : {
      "comment" : "Meldung bei ungültiger Währung",
      "extractionState" : "manual",
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Die Währung darf ein bis drei Zeichen haben: Buchstaben oder ein Währungszeichen, keine Ziffern. Bitte korrigieren. (currency)"
          }
        },
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "The currency must have one to three characters: letters or a currency sign, no digits. Please correct it. (currency)"
          }
        }
      }
    },
    "settings.currency.title" : {
      "comment" : "Einstellungen → Allgemein, Feld neben dem Strompreis",
      "extractionState" : "manual",
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Währung"
          }
        },
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Currency"
          }
        }
      }
    },
    "settings.language.english" : {
      "comment" : "Sprachwahl (Eigenname, nicht übersetzen)",
      "extractionState" : "manual",
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "English"
          }
        },
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "English"
          }
        }
      }
    },
    "settings.language.german" : {
      "comment" : "Sprachwahl (Eigenname, nicht übersetzen)",
      "extractionState" : "manual",
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Deutsch"
          }
        },
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Deutsch"
          }
        }
      }
    },
    "settings.language.restartHint" : {
      "comment" : "Hinweis unter der Sprachwahl",
      "extractionState" : "manual",
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Die Änderung wirkt nach einem Neustart der App."
          }
        },
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "The change takes effect after restarting the app."
          }
        }
      }
    },
    "settings.language.system" : {
      "comment" : "Sprachwahl: Sprache des Systems",
      "extractionState" : "manual",
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Systemsprache"
          }
        },
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "System language"
          }
        }
      }
    },
    "settings.language.title" : {
      "comment" : "Einstellungen → Allgemein, Überschrift der Sprachwahl",
      "extractionState" : "manual",
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Sprache"
          }
        },
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Language"
          }
        }
      }
    },
    "settings.language.unknown" : {
      "comment" : "Fehler des Bridge-Befehls `language`",
      "extractionState" : "manual",
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Diese Sprache kennt Klimacontrol nicht. Bitte eine andere wählen. (language-{value})"
          }
        },
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Klimacontrol does not know this language. Please choose another one. (language-{value})"
          }
        }
      }
    },
    "settings.price.invalid" : {
      "comment" : "Meldung bei ungültigem Strompreis",
      "extractionState" : "manual",
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Der Strompreis muss zwischen 0 und 1000 je kWh liegen. Bitte korrigieren. (price)"
          }
        },
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "The electricity price must be between 0 and 1000 per kWh. Please correct it. (price)"
          }
        }
      }
    },
    "settings.updates.betaChannel" : {
      "comment" : "Mac: Einstellungen → Allgemein → Updates, Schalter",
      "extractionState" : "manual",
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Vorabversionen (Beta) erhalten"
          }
        },
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Receive pre-release (beta) versions"
          }
        }
      }
    },
    "whatsNew.germanOnly" : {
      "comment" : "Erste Zeile einer Version ohne englischen CHANGELOG-Eintrag",
      "extractionState" : "manual",
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Die Versionshinweise zu dieser Version gibt es nur auf Deutsch."
          }
        },
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Release notes for this version are available in German only."
          }
        }
      }
    },
    "whatsNew.ok" : {
      "comment" : "Knopf im Fenster „Neu in …“",
      "extractionState" : "manual",
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "OK"
          }
        },
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "OK"
          }
        }
      }
    },
    "whatsNew.title" : {
      "comment" : "Titel des Fensters „Neu in …“ nach einem Update",
      "extractionState" : "manual",
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Neu in Klimacontrol {version}"
          }
        },
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "New in Klimacontrol {version}"
          }
        }
      }
    },
    "whatsNew.versionHeading" : {
      "comment" : "Überschrift je Version im Fenster „Neu in …“",
      "extractionState" : "manual",
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Version {version}"
          }
        },
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Version {version}"
          }
        }
      }
    }
  },
  "version" : "1.0"
}
"""#

    static let allKeys: [String] = [
        "bridge.formatInvalid",
        "bridge.localeUnreadable",
        "common.minutes",
        "settings.currency.invalid",
        "settings.currency.title",
        "settings.language.english",
        "settings.language.german",
        "settings.language.restartHint",
        "settings.language.system",
        "settings.language.title",
        "settings.language.unknown",
        "settings.price.invalid",
        "settings.updates.betaChannel",
        "whatsNew.germanOnly",
        "whatsNew.ok",
        "whatsNew.title",
        "whatsNew.versionHeading",
    ]

    /// Platzhalter je Schlüssel in der Reihenfolge der Parameter (Mehrzahl: zuerst "count").
    static let signatures: [String: [String]] = [
        "bridge.formatInvalid": [],
        "bridge.localeUnreadable": [],
        "common.minutes": ["count"],
        "settings.currency.invalid": [],
        "settings.currency.title": [],
        "settings.language.english": [],
        "settings.language.german": [],
        "settings.language.restartHint": [],
        "settings.language.system": [],
        "settings.language.title": [],
        "settings.language.unknown": ["value"],
        "settings.price.invalid": [],
        "settings.updates.betaChannel": [],
        "whatsNew.germanOnly": [],
        "whatsNew.ok": [],
        "whatsNew.title": ["version"],
        "whatsNew.versionHeading": ["version"],
    ]
}

/// Texte der Oberfläche, je Schlüssel des Katalogs ein Zugriff.
public enum L {
    public enum Bridge {
        /// The Windows format settings are incomplete. Numbers and times appear in German format. (bad-format)
        public static var formatInvalid: String { Localizer.text("bridge.formatInvalid") }
        /// The language and format settings could not be read. Please restart the app. (bad-locale)
        public static var localeUnreadable: String { Localizer.text("bridge.localeUnreadable") }
    }
    public enum Common {
        /// {count} minutes
        public static func minutes(count: Int) -> String { Localizer.plural("common.minutes", count: count) }
    }
    public enum Settings {
        public enum Currency {
            /// The currency must have one to three characters: letters or a currency sign, no digits. Please corre…
            public static var invalid: String { Localizer.text("settings.currency.invalid") }
            /// Currency
            public static var title: String { Localizer.text("settings.currency.title") }
        }
        public enum Language {
            /// English
            public static var english: String { Localizer.text("settings.language.english") }
            /// Deutsch
            public static var german: String { Localizer.text("settings.language.german") }
            /// The change takes effect after restarting the app.
            public static var restartHint: String { Localizer.text("settings.language.restartHint") }
            /// System language
            public static var system: String { Localizer.text("settings.language.system") }
            /// Language
            public static var title: String { Localizer.text("settings.language.title") }
            /// Klimacontrol does not know this language. Please choose another one. (language-{value})
            public static func unknown(value: String) -> String { Localizer.text("settings.language.unknown", ["value": value]) }
        }
        public enum Price {
            /// The electricity price must be between 0 and 1000 per kWh. Please correct it. (price)
            public static var invalid: String { Localizer.text("settings.price.invalid") }
        }
        public enum Updates {
            /// Receive pre-release (beta) versions
            public static var betaChannel: String { Localizer.text("settings.updates.betaChannel") }
        }
    }
    public enum WhatsNew {
        /// Release notes for this version are available in German only.
        public static var germanOnly: String { Localizer.text("whatsNew.germanOnly") }
        /// OK
        public static var ok: String { Localizer.text("whatsNew.ok") }
        /// New in Klimacontrol {version}
        public static func title(version: String) -> String { Localizer.text("whatsNew.title", ["version": version]) }
        /// Version {version}
        public static func versionHeading(version: String) -> String { Localizer.text("whatsNew.versionHeading", ["version": version]) }
    }
}
