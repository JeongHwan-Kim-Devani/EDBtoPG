BEGIN;

CREATE SCHEMA IF NOT EXISTS demo;

CREATE TABLE IF NOT EXISTS demo.customers (
  customer_id BIGSERIAL PRIMARY KEY,
  customer_name TEXT NOT NULL,
  email TEXT UNIQUE NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS demo.orders (
  order_id BIGSERIAL PRIMARY KEY,
  customer_id BIGINT NOT NULL REFERENCES demo.customers(customer_id),
  product_name TEXT NOT NULL,
  quantity INTEGER NOT NULL CHECK (quantity > 0),
  unit_price NUMERIC(12,2) NOT NULL CHECK (unit_price >= 0),
  ordered_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO demo.customers (customer_name, email)
VALUES
  ('Kim Minjun', 'minjun@example.com'),
  ('Lee Seoyeon', 'seoyeon@example.com'),
  ('Park Jiho', 'jiho@example.com')
ON CONFLICT (email) DO NOTHING;

WITH customer_map AS (
  SELECT customer_id, email
  FROM demo.customers
)
INSERT INTO demo.orders (customer_id, product_name, quantity, unit_price)
SELECT cm.customer_id, v.product_name, v.quantity, v.unit_price
FROM (
  VALUES
    ('minjun@example.com', 'Laptop', 1, 1499.00::NUMERIC),
    ('minjun@example.com', 'Mouse', 2, 25.50::NUMERIC),
    ('seoyeon@example.com', 'Monitor', 1, 320.00::NUMERIC),
    ('jiho@example.com', 'Keyboard', 1, 85.00::NUMERIC)
) AS v(email, product_name, quantity, unit_price)
JOIN customer_map cm ON cm.email = v.email
WHERE NOT EXISTS (
  SELECT 1
  FROM demo.orders o
  WHERE o.customer_id = cm.customer_id
    AND o.product_name = v.product_name
    AND o.quantity = v.quantity
    AND o.unit_price = v.unit_price
);

COMMIT;
