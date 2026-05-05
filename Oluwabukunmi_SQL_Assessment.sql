-- Q1. Where is the business concentrated?
SELECT 
	state,
	COUNT(*) AS customer_count,
	ROUND(100.0 * COUNT(*)/SUM(COUNT(*)) OVER(), 1) AS pct_of_total	
FROM customers
GROUP BY state
ORDER BY customer_count DESC
LIMIT 1;
/* Used GROUP BY to count customers per state and a window function to compute total
customers for percentage calculation. Ordered by customer count and limited to the
top state.*/

-- Q2. The silent customers
SELECT
	c.customer_id,
	CONCAT(c.first_name, ' ',c.last_name) AS full_name,
	c.signup_date,
	c.customer_segment
FROM customers c
LEFT JOIN orders o
	ON c.customer_id = o.customer_id
WHERE o.customer_id IS NULL
ORDER BY c.signup_date;
/*Used LEFT JOIN and filtered where no matching order exists (IS NULL).*/

-- Q3. Stock health check — with a twist
SELECT
	p.product_name,
	p.category,
	p.stock_quantity,
	p.supplier,
	COALESCE(SUM(oi.quantity), 0) AS total_sold,
	CASE
		WHEN p.stock_quantity = 0 THEN NULL
		ELSE ROUND(COALESCE(SUM(oi.quantity),0)::NUMERIC/p.stock_quantity,2)
	END AS demand_stock_ratio
FROM products p
LEFT JOIN order_items oi
	ON p.product_id = oi.product_id
GROUP BY p.product_id, p.product_name, p.category, p.stock_quantity, p.supplier
HAVING 
    p.stock_quantity = 0
    OR COALESCE(SUM(oi.quantity), 0)::numeric / NULLIF(p.stock_quantity, 0) > 1.5
ORDER BY demand_stock_ratio DESC;
/*Since sales velocity over time is not available, I approximated demand using
total quantity sold. Products with low stock relative to total demand are
considered at higher risk of running out. I ranked products by the ratio of 
quantity sold to stock quantity to identify the most urgent cases, I then filtered
by "at risk" products, cut-off was 1.5.*/

--Q4. Defining your "best" customer
SELECT
	CONCAT(c.first_name, ' ',c.last_name) AS full_name,
	c.state,
	c.customer_segment,
	COUNT(o.order_id) AS total_orders
FROM customers c
LEFT JOIN orders o
	ON c.customer_id = o.customer_id
GROUP BY c.customer_id, c.first_name, c.last_name, c.state, c.customer_segment
ORDER BY total_orders DESC
LIMIT 3;
/*defined the best customer as the one with the highest number of orders,
as this reflects consistent engagement and long-term value to the business.
While total spend is another valid metric, it may overvalue one-time large purchases,
whereas order frequency better captures customer loyalty and retention.
Three customers are tied at 10 orders — the top value — so all three are returned 
to reflect the tie rather than arbitrarily selecting one.*/

-- Q5. One-and-done vs repeat buyers
WITH customer_summary AS (
	SELECT
		c.customer_id,
		COUNT(DISTINCT o.order_id) AS no_of_orders,
		SUM((oi.unit_price - oi.discount) * oi.quantity) AS total_spend
	FROM customers c
	JOIN orders o
		ON c.customer_id = o.customer_id
	JOIN order_items oi
		ON o.order_id = oi.order_id
	GROUP BY c.customer_id
	)
SELECT 
	CASE 
		WHEN no_of_orders = 1 THEN 'one_and_done'
		ELSE 'repeat'
	END AS group_label,
	COUNT(customer_id) AS no_of_customers,
	SUM(total_spend) AS total_revenue,
	ROUND(SUM(total_spend)/COUNT(customer_id), 1) AS avg_revenue
FROM customer_summary
GROUP BY group_label;
/*First aggregated data at the customer level to compute order count and total 
spend. Then used a CASE expression to classify customers into one-and-done or
repeat buyers, and aggregated again to compute group-level metrics.*/

-- Q6. The dormant VIPs

WITH info AS (
	SELECT
		CONCAT(c.first_name, ' ',c.last_name) AS full_name,
		SUM((oi.unit_price - oi.discount) * oi.quantity) AS lifetime_spend,
		MAX(o.order_date) AS last_order_date,
		ABS((SELECT MAX(order_date) FROM orders) - MAX(o.order_date)) AS days_since_last_order
	FROM customers c
	JOIN orders o
		ON c.customer_id = o.customer_id
	JOIN order_items oi
		ON o.order_id = oi.order_id
	GROUP BY c.customer_id, c.first_name, c.last_name)
SELECT *
FROM info 
WHERE days_since_last_order >= 180 AND lifetime_spend >= 500000
ORDER BY lifetime_spend DESC;
/*Aggregated customer-level metrics (lifetime spend and last order date), 
then anchored “today” to the maximum order date in the dataset. Filtered for
high-value customers (≥ ₦500,000) who have not ordered in the last 180 days.*/

-- Q7. The 80/20 rule in action
WITH product_summary AS (
	SELECT 
		p.product_name,
		SUM((oi.unit_price - oi.discount) * oi.quantity) AS revenue		
	FROM products p
	JOIN order_items oi
		ON p.product_id = oi.product_id
	JOIN orders o
		ON oi.order_id = o.order_id
	GROUP BY p.product_id, p.product_name)
SELECT
	product_name,
	revenue,
	RANK() OVER (ORDER BY revenue DESC) AS position,
	SUM(revenue) OVER (ORDER BY revenue DESC) AS cummulative_revenue,
	ROUND(
	SUM(revenue) OVER (ORDER BY revenue DESC) * 100/ SUM(revenue) OVER(), 2
	) AS cummulative_pct,
	CASE
		WHEN SUM(revenue) OVER (ORDER BY revenue DESC) <= 0.8 * SUM(revenue) OVER()
		THEN TRUE
		ELSE FALSE
	END AS is_top_80
FROM product_summary;
/*Ranked products by revenue and used a window function to compute cumulative
revenue. Compared the running total to overall revenue to identify products
contributing to the first 80%, demonstrating the Pareto principle.
9 products account for 80% of revenue, suggesting the Pareto rule holds.*/

--Q8. What gets bought together?
SELECT
	p1.product_name AS product_a,
	p2.product_name AS product_b,
	COUNT(DISTINCT a.order_id) AS orders_together
FROM order_items a
JOIN order_items b
	ON a.order_id = b.order_id
	AND a.product_id < b.product_id
JOIN products p1
	ON a.product_id = p1.product_id
JOIN products p2
	ON b.product_id = p2.product_id
GROUP BY p1.product_name, p2.product_name
ORDER BY orders_together DESC
LIMIT 3;
/* Used a self-join on order_items to identify products appearing in the same 
order. Applied a.product_id < b.product_id to avoid duplicate and self-pairs,
and counted distinct orders to measure co-occurrence frequency.*/

-- Q9. Sales rep scorecard
WITH sales_employee_summary AS(
	SELECT
		e.employee_id,
		CONCAT(e.first_name, ' ', e.last_name) AS employee_name,
		COUNT(DISTINCT o.order_id) AS orders_handled,
		COALESCE(SUM((oi.unit_price - oi.discount) * oi.quantity), 0) AS gross_revenue_generated
	FROM employees e
	LEFT JOIN orders o
		ON e.employee_id = o.employee_id
	LEFT JOIN order_items oi 
		ON o.order_id = oi.order_id
	WHERE e.department = 'Sales'
	GROUP BY e.employee_id, e.first_name, e.last_name)
SELECT
	employee_name,
	orders_handled,
	gross_revenue_generated,
	ROUND(gross_revenue_generated/ NULLIF(orders_handled, 0), 2) AS average_order_value,
	ROUND(gross_revenue_generated * 100.0/ SUM(gross_revenue_generated) OVER(), 2) AS revenue_pct
FROM sales_employee_summary
ORDER BY gross_revenue_generated DESC;
/* Aggregated per Sales employee using LEFT JOIN to retain reps with zero orders.
Calculated total revenue and average order value, handling division by 
zero safely. Used a window function to compute each rep’s contribution to total 
team revenue.*/

-- Q10. Suspicious orders
WITH customer_summary AS (
	SELECT
		c.customer_id,
		CONCAT(c.first_name, ' ', c.last_name) AS customer_name,
		COUNT(DISTINCT o.order_id) AS total_orders,
		SUM((oi.unit_price - oi.discount) * oi.quantity) AS total_spend,
		ROUND(
			SUM((oi.unit_price - oi.discount) * oi.quantity)/ NULLIF(COUNT(DISTINCT o.order_id), 0)
			,2) AS avg_order_value
	FROM customers c
	JOIN orders o
	ON c.customer_id = o.customer_id
	JOIN order_items oi 
	ON o.order_id = oi.order_id
	GROUP BY c.customer_id, c.first_name, c.last_name),
order_summary AS(
	SELECT 
		o.order_id,
		o.customer_id,
		o.order_date,
		SUM((oi.unit_price - oi.discount) * oi.quantity) AS this_order_value
	FROM orders o
	JOIN order_items oi
		ON o.order_id = oi.order_id
	GROUP BY o.order_id, o.customer_id, o.order_date)
SELECT 
	os.order_id,
	cs.customer_name,
	os.order_date,
	os.this_order_value,
	cs.avg_order_value AS customer_avg_order_value,
	ROUND(
		os.this_order_value / cs.avg_order_value
		, 2) AS multiplier
FROM customer_summary cs
JOIN order_summary os
	ON cs.customer_id = os.customer_id
WHERE cs.total_orders >= 3 AND os.this_order_value >= 5 * cs.avg_order_value
ORDER BY multiplier DESC;
/* Computed customer-level average order value and filtered for customers
with at least three orders. Calculated each order’s total value separately and
compared it against the customer’s average to identify unusually large (≥5×) 
transactions.*/




















