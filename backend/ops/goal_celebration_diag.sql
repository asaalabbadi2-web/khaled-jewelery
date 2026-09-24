-- Goal achievement celebration — why it stopped appearing.
--
-- The celebration chain is:
--   home_screen_enhanced.dart _checkForAchievements()
--     -> POST /api/achievements/check-progress  (routes/employees.py check_goal_progress)
--     -> GET  /api/achievements/unseen
--
-- Every failure mode in that chain returns an empty list with HTTP 200, so the
-- UI cannot distinguish "no achievement earned" from "employee not linked to a
-- user account" from "backend raised". These queries separate them.
--
-- Run order matters: 4 closes the most mundane cause first (already seen),
-- 6 is the decisive one (did creation collapse on a deploy date?).
--
-- Usage (production, Windows + Docker Compose):
--   docker compose exec -T db psql -U yasargold -d yasargold_db < goal_celebration_diag.sql

\echo '=== 1) إعدادات النقاط (points_source يحدد صيغة الحساب) ==='
-- points_source drives points/engine.py: 'gold_weight' (default) normalizes each
-- item by karat/main_karat; 'profit_cash' divides by cash_amount_per_point.
-- Commit 6ff6b10 switched goal achievement onto this engine — before it was a
-- flat sum(profit_gold) * points_per_gram.
SELECT id, updated_at, sales_race_settings
FROM settings
ORDER BY updated_at DESC NULLS LAST, id DESC
LIMIT 1;

\echo ''
\echo '=== 2) أهداف الموظفين: هل هي مفعّلة وهل لها قيم؟ ==='
-- A target of NULL or 0 is skipped silently (employees.py: `if target <= 0: continue`).
-- goal_metric selects which of the three target columns is read.
SELECT id, name, is_active,
       COALESCE(goal_metric,'weight') AS metric,
       goal_daily_enabled   AS d_on, goal_weekly_enabled AS w_on, goal_monthly_enabled AS m_on,
       goal_points_daily    AS p_d,  goal_points_weekly  AS p_w,  goal_points_monthly  AS p_m,
       goal_weight_daily    AS g_d,  goal_weight_weekly  AS g_w,  goal_weight_monthly  AS g_m,
       goal_invoices_daily  AS i_d,  goal_invoices_weekly AS i_w, goal_invoices_monthly AS i_m
FROM employee
WHERE is_active = true
ORDER BY id;

\echo ''
\echo '=== 3) هل الموظف مربوط بحساب مستخدم؟ (بدونه لا يعمل check-progress أبداً) ==='
-- check_goal_progress returns [] immediately when current_user.employee_id is NULL.
-- A NULL user_id here means that employee can never see a celebration.
SELECT e.id AS employee_id, e.name, u.id AS user_id, u.username
FROM employee e
LEFT JOIN app_user u ON u.employee_id = e.id
WHERE e.is_active = true
ORDER BY e.id;

\echo ''
\echo '=== 4) إنجازات الفترة الحالية: seen_by_user=true يعني لن تظهر ثانيةً (سلوك مقصود) ==='
-- This is the mundane explanation. One celebration per period_key, by design.
-- It only re-fires if the bonus went 0 -> positive, or the target value changed.
SELECT id, employee_id, period_key, goal_period, goal_name,
       bonus_amount, seen_by_user, seen_at, achieved_at,
       metrics::text AS metrics
FROM goal_achievement
WHERE period_key IN (
        'daily-'   || to_char(now(), 'YYYY-MM-DD'),
        'weekly-'  || to_char(now(), 'IYYY') || '-W' || to_char(now(), 'IW'),
        'monthly-' || to_char(now(), 'YYYY-MM')
      )
ORDER BY employee_id, goal_period;

\echo ''
\echo '=== 5) آخر 15 إنجازاً: متى توقّف الإنشاء فعلياً؟ ==='
SELECT id, employee_id, period_key, goal_period,
       bonus_amount, seen_by_user, achieved_at
FROM goal_achievement
ORDER BY achieved_at DESC
LIMIT 15;

\echo ''
\echo '=== 6) عدّاد شهري: هل انهار الإنشاء عند تاريخ معيّن؟ (6ff6b10 نُشر 2026-08-03) ==='
-- The decisive query. A cliff at 2026-08 points at the points-formula change;
-- a gradual decline points at targets or trading volume instead.
SELECT to_char(achieved_at, 'YYYY-MM') AS month,
       COUNT(*) AS achievements
FROM goal_achievement
GROUP BY 1
ORDER BY 1 DESC
LIMIT 12;

\echo ''
\echo '=== 7) هل بنود الفواتير تحمل profit_weight؟ (صفر ⇒ المحرك يسقط على profit_gold) ==='
-- points/engine.py gold_weight mode reads InvoiceItem.profit_weight and falls back
-- to Invoice.profit_gold only when an invoice contributes nothing. A month where
-- items_with_pw is 0 but sum_invoice_profit_gold is large means every invoice is
-- taking the fallback path, which scores differently from the per-item path.
SELECT to_char(i.date, 'YYYY-MM') AS month,
       COUNT(DISTINCT i.id)                                        AS invoices,
       COUNT(it.id)                                                AS items,
       COUNT(it.id) FILTER (WHERE COALESCE(it.profit_weight,0) > 0) AS items_with_pw,
       ROUND(SUM(COALESCE(it.profit_weight,0))::numeric, 3)        AS sum_profit_weight,
       ROUND(SUM(COALESCE(i.profit_gold,0))::numeric, 3)           AS sum_invoice_profit_gold
FROM invoice i
LEFT JOIN invoice_item it ON it.invoice_id = i.id
WHERE i.invoice_type IN ('بيع','sell','sale')
  AND i.is_posted = true
  AND i.date >= now() - interval '6 months'
GROUP BY 1
ORDER BY 1 DESC;
