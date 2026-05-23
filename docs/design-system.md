# Design System

> תיעוד מלא של הפלטה והרכיבים. כרגע סקיצה.

## פלטה נוכחית

| תפקיד | משתנה | ערך |
|---|---|---|
| רקע | `--bg` | `#FFF9F1` |
| רקע מוגבה | `--bg-elev` | `#FFFFFF` |
| טקסט ראשי | `--ink` | `#1F1B16` |
| טקסט משני | `--ink-soft` | `#4A4339` |
| מבטא קורל | `--accent` | `#E76F51` |
| מבטא בהיר | `--accent-light` | `#F4A261` |
| מבטא עמוק | `--accent-deep` | `#C2553A` |
| משני (טורקיז) | `--secondary` | `#2A9D8F` |
| מומלץ (זהב) | `--tertiary` | `#E9C46A` |
| הצלחה | `--keep` | `#43AA8B` |
| שגיאה | `--error` | `#E63946` |

## גרדיאנטים

- `--grad-warm` — Coral → Orange → Gold (135°)
- `--grad-sunset` — Coral → Deep coral (135°)
- `--grad-cool` — Teal → Light teal (135°)

## טיפוגרפיה

- **כותרות**: Frank Ruhl Libre (serif)
- **גוף**: Heebo (sans-serif)
- **גודלים**: 12, 13, 14, 15, 16, 17, 18, 22, 24, 26, 28, 30, 36, 38

## רכיבים עיקריים

- כפתורים: primary (גרדיאנט), secondary (transparent + border)
- שדות קלט: 1.5px border, 12px radius, focus ring
- כרטיסי שאלה: 14px radius, מסגרת רכה, מעבר רך
- Likert: 5 עיגולים, 66px, מתמלאים בגרדיאנט בנבחר
- צ׳קבוקס: כרטיסים גדולים עם ✓
- Section icons: emoji מותאמי גיל (🧒🏡🤗🤝🚦🧩🤸🎮🎒😴🌈🦸🏆💬)
- Floating blobs: 3 ספוטים גרדיאנט מטושטשים, אנימציה איטית
- Confetti: 80 חתיכות צבעוניות בסיום

## TODO

- [ ] תיעוד פורמלי של כל הרכיבים עם דוגמאות
- [ ] Storybook / showcase
- [ ] Light + Dark modes
