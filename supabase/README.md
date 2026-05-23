# Supabase Setup — Phase 2

מדריך מהיר להקמת ה-backend ב-Supabase ולקישור לאפליקציה.

---

## 1. יצירת פרויקט (חד פעמי)

1. הירשם ב-https://supabase.com (חינמי)
2. **New Project**:
   - Name: `parents-questionnaire`
   - Database Password: שמור בצד (נצטרך רק אם נתחבר ידנית)
   - Region: **West Europe (London)** — הכי קרוב לישראל
   - Plan: **Free**
3. המתן ~2 דקות עד שהפרויקט מוכן

---

## 2. הרצת ה-Schema

1. ב-Dashboard, היכנס ל-**SQL Editor** → **New query**
2. העתק את התוכן של `schema.sql` לחלון
3. **Run** (Ctrl+Enter)
4. אם הכל ירוק — המבנה מוכן ✅

מה נוצר:
- 📋 טבלת `profiles` (הרחבה של `auth.users` עם שם הילד וכו׳)
- 📋 טבלת `submissions` (כל ההגשות, עם answers כ-JSONB)
- 🔒 RLS פעיל — הורה רואה רק שלו, אדמין רואה הכל
- ⚡ טריגר אוטומטי שיוצר profile בכל הרשמה
- 📡 Realtime פעיל על submissions

---

## 3. השגת ה-API credentials

ב-Dashboard → **Settings** → **API**:

| מה צריך | איך נראה |
|---|---|
| **Project URL** | `https://xxxxxxxx.supabase.co` |
| **anon public key** | `eyJ...` ארוך |

שמור אותם — נשתמש בהם בקוד.

⚠️ **service_role key** — אל תשתף עם אף אחד (לא בקוד client-side, לא בגיט). הוא לא נצטרך כרגע.

---

## 4. הפיכת חשבון לאדמין

לאחר שתירשם דרך האפליקציה בפעם הראשונה:

```sql
update public.profiles
   set is_admin = true
 where email = 'your-admin@email.com';
```

הרץ ב-SQL Editor. צא והיכנס מחדש לאפליקציה כדי לרענן את ה-JWT — תקבל גישה ללוח האדמין המלא.

---

## 5. הגדרת התראות אימייל (Phase 2.D, לא חובה ב-Phase 2.A)

יש 2 אופציות:
- **Database Webhooks** (Dashboard → Database → Webhooks) → לשלוח POST ל-Zapier / Make.com / שירות מייל
- **Edge Function** + Resend.com → קוד server-side שמשלח מייל עם תוכן ההגשה

נכין בנפרד אחרי שהבסיס יעבוד.

---

## הערות אבטחה

- **anon key בטוח לחשיפה**: בעיני RLS הוא רק "מי שמדבר עם ה-API" — לא מקנה הרשאות.
- **service_role לעולם לא ב-frontend**: עוקף את כל ה-RLS — שמירה אצלך בלבד.
- **Auth Email Templates**: Dashboard → Authentication → Email Templates — אפשר לעצב את מיילי האימות והשחזור בעברית.
