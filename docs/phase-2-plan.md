# Phase 2 — Real Backend (Supabase)

תכנית מפורטת להגירה מ-localStorage ל-Supabase.

## יעדים

1. **סנכרון בין מכשירים** — הורה ממלא בטלפון, מטפלת רואה במחשב מיידית
2. **שליחה אוטומטית** — בלי mailto, בלי לחיצה ידנית
3. **אימות אמיתי** — אימייל מאומת, שחזור סיסמה דרך לינק במייל
4. **הגנת מידע** — RLS, סיסמאות hashed (Supabase מטפלת)
5. **בסיס לסגמנטים** — `detected_segments` בטבלה מוכן ל-Phase 3

---

## A. הקמת Supabase ✅ — הצעד הראשון

ראה `supabase/README.md`.

הקלט שאני צריך ממך כדי להמשיך:
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`

---

## B. Schema ✅ — מוכן

ראה `supabase/schema.sql`. שני stub-ים עיקריים:

| טבלה | תפקיד | RLS |
|---|---|---|
| `profiles` | מידע מורחב של המשתמש (שם, שם ילד, טלפון, is_admin) | רק הבעלים / אדמין |
| `submissions` | כל הגשה — answers כ-JSONB | רק הבעלים יוצר/קורא; אדמין רואה הכל |

---

## C. החלפת קוד באפליקציה — מה ישתנה

### `public/index.html` — שינויים נדרשים

**מה נשאר (לא משתנה):**
- כל ה-UI (הרשמה / כניסה / שאלון / הפוגות / סיום)
- מבנה הנתונים (`DATA`, `FLAT`, `state.answers`)
- האנימציות והעיצוב

**מה משתנה:**

| תפקיד | היום (localStorage) | אחרי (Supabase) |
|---|---|---|
| הרשמה | `users[email] = {hash, ...}` ב-localStorage | `supabase.auth.signUp({ email, password, data: { full_name, child_name, phone } })` |
| כניסה | בדיקת hash מקומית | `supabase.auth.signInWithPassword(...)` |
| Session | `localStorage.getItem('parentq_session_v1')` | `supabase.auth.getSession()` (אוטומטי) |
| שחזור סיסמה | mailto + 6-digit code מקומי | `supabase.auth.resetPasswordForEmail(...)` → לינק במייל |
| שמירת תשובות בזמן השאלון | `parentq_answers_<email>` ב-localStorage | **נשארת ב-localStorage** (cache מהיר) + auto-sync ל-DB כל X שניות |
| הגשה סופית | mailto + JSON download | `supabase.from('submissions').insert({...})` + webhook לאדמין |
| לוח אדמין | `parentq_submissions_v1` ב-localStorage | `supabase.from('submissions_with_user').select('*')` + Realtime subscription |

### `public/review.html` (כלי הסקירה) — מינוריות
- ממשיך לעבוד כסקירה ידנית
- בעתיד: אפשר לשמור החלטות סקירה ב-DB

### `public/form.html` (טופס סטטי)
- אין שינוי — נשאר ל-fallback ידני

---

## D. התראות וסנכרון

### Realtime לאדמין
```js
supabase
  .channel('submissions-feed')
  .on('postgres_changes',
      { event: 'INSERT', schema: 'public', table: 'submissions' },
      payload => renderNewSubmission(payload.new))
  .subscribe();
```
כל הגשה חדשה → מופיעה בלוח האדמין בזמן אמת בלי refresh.

### התראת אימייל
2 דרכים, כל אחת ~30 דק׳ להגדיר:

**אופציה 1 — Database Webhook (קל):**
- Dashboard → Database → Webhooks → New
- Event: `INSERT` on `submissions`
- URL: Make.com / Zapier / IFTTT webhook שמייצר מייל

**אופציה 2 — Edge Function + Resend (מקצועי):**
- כותבים Function ב-Deno שקוראת ל-Resend API
- חינמי עד 3,000 מיילים/חודש
- שליטה מלאה על תבנית המייל

---

## E. הגירת נתונים קיימים (אופציונלי)

אם יש משתמשים קיימים שכבר מילאו את השאלון ב-localStorage:

```js
// One-time migration script
async function migrateLocalToSupabase() {
  const localSubs = JSON.parse(localStorage.getItem('parentq_submissions_v1') || '[]');
  for (const sub of localSubs) {
    // 1. Try to sign up the user
    // 2. Insert submission with user_id
  }
}
```

נכין כפתור "ייבא הגשות קודמות" בלוח האדמין.

---

## תכנון זמנים (אומדן)

| שלב | עבודה | זמן משוער |
|---|---|---|
| A. Supabase signup + schema | אתה: 5 דק׳, אני: 0 (מוכן) | 5 דק׳ |
| C.1. Auth migration | החלפת register/login/forgot ל-Supabase Auth | 1-2 שעות |
| C.2. Submission save | החלפת mailto/download ב-DB insert | 30 דק׳ |
| C.3. Admin list refactor | החלפת localStorage ב-SQL query | 1 שעה |
| D.1. Realtime | הוספת subscription לאדמין | 30 דק׳ |
| D.2. Email webhook | יחד — תלוי בבחירת השירות | 1 שעה |
| בדיקות end-to-end | סבב מלא של כל הזרימה | 1 שעה |
| **סה"כ** | | **~5-7 שעות עבודה ביחד** |

---

## סדר ביצוע מוצע (לאחר שיש לי URL+anon key)

1. **commit להוספת תלות**: הוספת Supabase JS SDK ב-`public/index.html` (CDN — אין npm install)
2. **קונפיגורציה**: יצירת `public/supabase-config.js` עם URL+anon key (לא ב-gitignore — אלה ערכים ציבוריים)
3. **migration of Auth**: שלב אחר שלב — register, login, session, logout, password reset
4. **migration of Submissions**: שמירה + טעינה
5. **migration of Admin dashboard**: list, search, view
6. **הוספת Realtime**
7. **התראות אימייל**
8. **smoke test מלא**
9. **commit + push לסיום Phase 2**

לאחר הסיום — האפליקציה תעבוד מכל מכשיר, מסונכרנת, עם אימות אמיתי. בסיס מוצק ל-Phase 3 (סגמנטים) ו-Phase 4 (תכניות).
