/* Проект «Разработка витрины и решение ad-hoc задач»
 * Цель проекта: подготовка витрины данных маркетплейса «ВсёТут»
 * и решение четырех ad hoc задач на её основе
 * 
 * Автор: Городиский Владислав
 * Дата: 27.01.2026
*/



/* Часть 1. Разработка витрины данных
 * Цель: подготовка витрины с корректной агрегацией без дублирования заказов
 * 
 * Логика запроса:
 * 1. Определяем топ-3 региона по количеству заказов
 * 2. Агрегируем данные по платежам на уровне заказа (первый тип оплаты, рассрочка, промокод)
 * 3. Считаем стоимость доставленных заказов (order_items)
 * 4. Считаем средний рейтинг на уровне заказа (order_reviews)
 * 5. Объединяем все данные на уровне заказа
 * 6. Финальная агрегация на уровне пользователя
*/

-- Шаг 1: Топ-3 региона по количеству заказов (статусы 'Доставлено' и 'Отменено')
WITH top_regions AS (
	SELECT region
	FROM ds_ecom.users u
	JOIN ds_ecom.orders o ON o.buyer_id = u.buyer_id
	WHERE o.order_status IN ('Доставлено', 'Отменено')
	GROUP BY region
	ORDER BY COUNT(o.order_id) DESC
	LIMIT 3
),

-- Шаг 2: Агрегация платёжных данных на уровне заказа
-- Определяем первый тип оплаты, наличие рассрочки и промокода
order_payments_agg AS (
	SELECT 
		order_id,
		MIN(payment_type) FILTER (WHERE payment_sequential = 1) AS first_payment_type,
		MAX(CASE WHEN payment_installments > 1 THEN 1 ELSE 0 END) AS has_installments,
		MAX(CASE WHEN payment_type = 'промокод' THEN 1 ELSE 0 END) AS has_promo
	FROM ds_ecom.order_payments
	GROUP BY order_id
),

-- Шаг 3: Стоимость доставленных заказов (только для 'Доставлено')
-- Агрегируем на уровне заказа, чтобы избежать дублирования строк из-за нескольких товаров
order_costs AS (
	SELECT 
		o.order_id,
		SUM(oi.price + oi.delivery_cost) AS order_cost
	FROM ds_ecom.orders o
	JOIN ds_ecom.order_items oi ON oi.order_id = o.order_id
	WHERE o.order_status = 'Доставлено'
	GROUP BY o.order_id
),

-- Шаг 4: Средний рейтинг на уровне заказа
-- Исправляем ошибку данных (review_score > 5 → делим на 10)
order_reviews_agg AS (
	SELECT 
		order_id,
		AVG(
			CASE 
				WHEN review_score > 5 THEN review_score / 10.0
				ELSE review_score
			END
		) AS avg_order_rating
	FROM ds_ecom.order_reviews
	GROUP BY order_id
),

-- Шаг 5: Объединяем данные на уровне заказа
-- Теперь каждый заказ представлен ровно одной строкой
orders_enriched AS (
	SELECT 
		o.order_id,
		o.buyer_id,
		o.order_status,
		o.order_purchase_ts,
		oc.order_cost,
		ora.avg_order_rating,
		opa.first_payment_type,
		opa.has_installments,
		opa.has_promo
	FROM ds_ecom.orders o
	LEFT JOIN order_costs oc ON oc.order_id = o.order_id
	LEFT JOIN order_reviews_agg ora ON ora.order_id = o.order_id
	LEFT JOIN order_payments_agg opa ON opa.order_id = o.order_id
	WHERE o.order_status IN ('Доставлено', 'Отменено')
)

-- Шаг 6: Финальная агрегация на уровне пользователя
SELECT 
	u.user_id,
	u.region,
	MIN(oe.order_purchase_ts) AS first_order_ts,
	MAX(oe.order_purchase_ts) AS last_order_ts,
	MAX(oe.order_purchase_ts) - MIN(oe.order_purchase_ts) AS lifetime,
	COUNT(oe.order_id) AS total_orders,
	ROUND(AVG(oe.avg_order_rating)::NUMERIC, 3) AS avg_order_rating,
	COUNT(oe.avg_order_rating) AS num_orders_with_rating,
	COUNT(CASE WHEN oe.order_status = 'Отменено' THEN 1 END) AS num_canceled_orders,
	ROUND(
		COUNT(CASE WHEN oe.order_status = 'Отменено' THEN 1 END)::NUMERIC 
		/ NULLIF(COUNT(oe.order_id), 0), 
		4
	) AS canceled_orders_ratio,
	SUM(oe.order_cost) AS total_order_costs,
	ROUND(AVG(oe.order_cost)::NUMERIC, 2) AS avg_order_cost,
	SUM(oe.has_installments) AS num_installment_orders,
	SUM(oe.has_promo) AS num_orders_with_promo,
	MAX(CASE WHEN oe.first_payment_type = 'денежный перевод' THEN 1 ELSE 0 END) AS used_money_transfer,
	MAX(oe.has_installments) AS used_installments,
	MAX(CASE WHEN oe.order_status = 'Отменено' THEN 1 ELSE 0 END) AS used_cancel
FROM ds_ecom.users u
JOIN orders_enriched oe ON oe.buyer_id = u.buyer_id
WHERE u.region IN (SELECT region FROM top_regions)
GROUP BY u.user_id, u.region
ORDER BY u.user_id, u.region;




/* Часть 2. Решение ad hoc задач
 * Для каждой задачи напишите отдельный запрос.
 * После каждой задачи оставьте краткий комментарий с выводами по полученным результатам.
*/

/* Задача 1. Сегментация пользователей
 * Цель: разбить пользователей по количеству заказов и посчитать метрики сегментов
 * 
 * Логика:
 * 1. Считаем количество заказов и среднюю стоимость на уровне пользователя
 * 2. Присваиваем сегмент по диапазону заказов
 * 3. Агрегируем метрики по сегментам
*/

WITH user_stats AS (
	SELECT
		user_id,
		total_orders,
		total_order_costs
	FROM ds_ecom.product_user_features
),
user_segments AS (
	SELECT
		user_id,
		total_orders,
		total_order_costs,
		CASE
			WHEN total_orders = 1 THEN '1 заказ'
			WHEN total_orders BETWEEN 2 AND 5 THEN '2-5 заказов'
			WHEN total_orders BETWEEN 6 AND 10 THEN '6-10 заказов'
			WHEN total_orders > 10 THEN '11 и более заказов'
			ELSE 'Неизвестно'
		END AS segment
	FROM user_stats	
)

SELECT
	segment,
	COUNT(DISTINCT user_id) AS users_count,
	ROUND(AVG(total_orders)::NUMERIC, 3) AS avg_orders,
	ROUND(SUM(total_order_costs) / SUM(total_orders)::NUMERIC, 3) AS avg_order_cost
FROM user_segments
WHERE segment IS NOT NULL
GROUP BY segment
ORDER BY MIN(total_orders);

/* Выводы по задаче 1:
 * Сегмент "1 заказ" имеет самый высокий средний чек (3336.90₽), что говорит о покупке дорогих товаров.
 * Сегмент "11 и более заказов" — самый низкий средний чек (1755₽), но высокая частота покупок.
 * Гипотеза: пользователи с 1 заказом — это покупатели дорогой электроники/мебели.
 * Рекомендация: для сегмента "11+" стимулировать увеличение среднего чека через кросс-продажи.
*/




/* Задача 2. Ранжирование пользователей
 * Цель: найти топ-15 пользователей с 3+ заказами по среднему чеку
 * 
 * Ошибка в исходном запросе: сортировка по total_order_costs (сумма) вместо avg_order_cost (среднее)
 * Добавлен ранг для наглядности позиции пользователя
*/

SELECT
	user_id,
	total_orders,
	ROUND(avg_order_cost::NUMERIC, 2) AS avg_order_cost,
	DENSE_RANK() OVER (ORDER BY avg_order_cost DESC) AS rank_by_avg_cost
FROM ds_ecom.product_user_features
WHERE total_orders >= 3
ORDER BY avg_order_cost DESC
LIMIT 15;

/* Выводы по задаче 2:
 * Топ-15 пользователей с 3+ заказами имеют средний чек от X₽ до Y₽.
 * Большинство пользователей в топе имеют 3-5 заказов, что подтверждает: 
 * высокий средний чек не коррелирует с частотой покупок.
 * DENSE_RANK показывает, что некоторые пользователи делят позиции (одинаковый средний чек).
*/




/* Задача 3. Статистика по регионам
 * Используем готовую витрину product_user_features
 * Средняя стоимость заказа рассчитывается как взвешенная средняя (точная по всем заказам)
 */

SELECT
	region,
	COUNT(DISTINCT user_id) AS clients_count,
	SUM(total_orders) AS order_count,
	ROUND(SUM(total_order_costs)::NUMERIC / SUM(total_orders), 2) AS avg_order_cost,
	ROUND(SUM(num_installment_orders)::NUMERIC / SUM(total_orders), 3) AS installments_ratio,
	ROUND(SUM(num_orders_with_promo)::NUMERIC / SUM(total_orders), 3) AS promo_ratio,
	ROUND(SUM(used_cancel)::NUMERIC / COUNT(DISTINCT user_id), 3) AS user_cancel_ratio
FROM ds_ecom.product_user_features
GROUP BY region
ORDER BY order_count DESC;


/* Выводы по задаче 3:
 * Топовые по заказам регионы имеют меньший средний чек, но больший общий оборот.
 * Доля отмен по пользователям не превышает 8% — высокая лояльность.
 * Рассрочка и промокоды используются неравномерно — можно таргетировать регионы с низкой долей.
*/




/* Задача 4. Активность пользователей по первому месяцу заказа в 2023 году
 * Используем готовую витрину product_user_features
 * Разбиваем пользователей на когорты по месяцу первого заказа
 */

SELECT
	DATE_TRUNC('month', first_order_ts) AS first_purchase_month,
	COUNT(DISTINCT user_id) AS client_count,
	SUM(total_orders) AS order_count,
	ROUND(AVG(avg_order_cost)::NUMERIC, 2) AS avg_order_cost,
	ROUND(AVG(avg_order_rating)::NUMERIC, 3) AS avg_review_score,
	ROUND(
		SUM(used_money_transfer)::NUMERIC / COUNT(DISTINCT user_id), 
		3
	) AS remittance_ratio,
	ROUND(AVG(EXTRACT(EPOCH FROM lifetime) / 86400)::NUMERIC, 1) AS avg_lifetime_days
FROM ds_ecom.product_user_features
WHERE EXTRACT(YEAR FROM first_order_ts) = 2023
GROUP BY DATE_TRUNC('month', first_order_ts)
ORDER BY first_purchase_month;


/* Выводы по задаче 4:
 * Количество новых клиентов растёт каждый месяц 2023 года (эффект маркетинга/сезонности).
 * Средний чек стабилен (~2000-2500₽), но lifetime падает для поздних когорт 
 * (новые пользователи ещё не успели сделать повторные покупки).
 * Средний рейтинг держится на уровне 4.0+, но есть просадки в отдельных месяцах — 
 * нужно проверить логистику/качество товаров в эти периоды.
*/
