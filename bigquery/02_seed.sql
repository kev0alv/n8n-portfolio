-- =====================================================================
-- Stride & Soul — seed data
-- Run 2 of 5. Safe to re-run: MERGE only inserts missing rows and
-- refreshes texts; it never resets stock that sales already consumed.
-- =====================================================================

-- ---------------------------------------------------------------- settings
MERGE stride_soul.settings t
USING (
  SELECT 'tax_rate' AS key, '0.13' AS value, 'Sales tax included in catalog prices (13% = El Salvador VAT)' AS description UNION ALL
  SELECT 'ticket_prefix',          'SS-',  'Prefix of receipt numbers: SS-000001' UNION ALL
  SELECT 'currency',               'USD',  'Currency of every amount' UNION ALL
  SELECT 'shipping_fee',           '2.00', 'Flat shipping fee per order' UNION ALL
  SELECT 'free_shipping_min_pairs','2',    'Orders with at least this many pairs ship free' UNION ALL
  SELECT 'return_window_days',     '14',   'Days after delivery to request an exchange'
) s
ON t.key = s.key
WHEN MATCHED THEN UPDATE SET value = s.value, description = s.description
WHEN NOT MATCHED THEN INSERT (key, value, description) VALUES (s.key, s.value, s.description);

-- ---------------------------------------------------------------- counters
MERGE stride_soul.counters t
USING (SELECT 'ticket' AS name UNION ALL SELECT 'support_case') s
ON t.name = s.name
WHEN NOT MATCHED THEN INSERT (name, value) VALUES (s.name, 0);

-- ---------------------------------------------------------------- catalog (40 variants)
MERGE stride_soul.catalog t
USING (
  SELECT * FROM UNNEST([
    STRUCT(1 AS product_id, '1460 Smooth' AS model, 'Dr. Martens' AS brand, 'boots' AS type, 'punk' AS subculture, '35-44' AS size_range, 'Black' AS color, 189.00 AS price, 12 AS stock),
    (2,  '1460 Smooth',              'Dr. Martens', 'boots',       'goth',          '35-44', 'Cherry Red',        199.00, 8),
    (3,  '1461 Smooth',              'Dr. Martens', 'shoes',       'straight edge', '36-44', 'Black',             169.00, 15),
    (4,  '1461 Mono',                'Dr. Martens', 'shoes',       'goth',          '36-44', 'Matte Black',       175.00, 6),
    (5,  'Jadon Platform',           'Dr. Martens', 'boots',       'goth',          '35-42', 'Black',             229.00, 9),
    (6,  'Jadon Platform',           'Dr. Martens', 'boots',       'emo',           '35-42', 'Black Patent',      239.00, 5),
    (7,  '2976 Chelsea',             'Dr. Martens', 'ankle boots', 'punk',          '36-44', 'Black',             199.00, 10),
    (8,  '2976 Chelsea',             'Dr. Martens', 'ankle boots', 'metal',         '36-44', 'Gunmetal',          209.00, 4),
    (9,  '1490 Mid',                 'Dr. Martens', 'boots',       'hardcore',      '37-45', 'Black',             209.00, 7),
    (10, '1914 Tall',                'Dr. Martens', 'boots',       'punk',          '36-43', 'Black',             249.00, 3),
    (11, 'Sinclair Platform',        'Dr. Martens', 'boots',       'goth',          '35-42', 'Black',             259.00, 6),
    (12, 'Gryphon Strap',            'Dr. Martens', 'sandals',     'punk',          '36-44', 'Black',             129.00, 11),
    (13, 'Blaire Slide',             'Dr. Martens', 'sandals',     'emo',           '35-42', 'Black',             99.00,  14),
    (14, 'Combs Tech',               'Dr. Martens', 'boots',       'metal',         '37-46', 'Black',             219.00, 5),
    (15, 'Audrick Platform',         'Dr. Martens', 'ankle boots', 'goth',          '35-42', 'Black Nappa',       245.00, 4),
    (16, 'Chuck Taylor All Star Hi', 'Converse',    'sneakers',    'punk',          '35-46', 'Black',             65.00,  25),
    (17, 'Chuck Taylor All Star Hi', 'Converse',    'sneakers',    'emo',           '35-46', 'Red',               65.00,  18),
    (18, 'Chuck Taylor All Star Low','Converse',    'sneakers',    'straight edge', '35-46', 'Black',             60.00,  30),
    (19, 'Chuck Taylor All Star Low','Converse',    'sneakers',    'hardcore',      '35-46', 'White',             60.00,  22),
    (20, 'Chuck 70 Hi',              'Converse',    'sneakers',    'punk',          '36-45', 'Vintage Black',     89.00,  12),
    (21, 'Chuck 70 Hi',              'Converse',    'sneakers',    'emo',           '36-45', 'Burgundy',          89.00,  9),
    (22, 'All Star Platform Hi',     'Converse',    'sneakers',    'goth',          '35-42', 'Black',             95.00,  10),
    (23, 'Chuck Taylor Lugged',      'Converse',    'ankle boots', 'goth',          '35-43', 'Black',             110.00, 7),
    (24, 'All Star Hi Leather',      'Converse',    'sneakers',    'metal',         '36-46', 'Black Leather',     99.00,  8),
    (25, 'Chuck Taylor Hi Studs',    'Converse',    'sneakers',    'punk',          '35-44', 'Black Studded',     105.00, 6),
    (26, 'Run Star Hike Hi',         'Converse',    'sneakers',    'emo',           '35-45', 'Black/White',       120.00, 9),
    (27, 'Chuck 70 Plus',            'Converse',    'sneakers',    'hardcore',      '36-46', 'Black',             115.00, 5),
    (28, 'Old Skool',                'Vans',        'sneakers',    'hardcore',      '35-46', 'Black/White',       70.00,  28),
    (29, 'Old Skool',                'Vans',        'sneakers',    'straight edge', '35-46', 'Black Mono',        72.00,  20),
    (30, 'Sk8-Hi',                   'Vans',        'sneakers',    'punk',          '35-46', 'Black/White',       80.00,  17),
    (31, 'Sk8-Hi',                   'Vans',        'sneakers',    'emo',           '35-46', 'All Black',         82.00,  13),
    (32, 'Authentic',                'Vans',        'sneakers',    'straight edge', '35-46', 'Black',             60.00,  26),
    (33, 'Era',                      'Vans',        'sneakers',    'hardcore',      '35-46', 'Black/Gum',         62.00,  19),
    (34, 'Sk8-Hi MTE',               'Vans',        'ankle boots', 'metal',         '36-46', 'Black Waterproof',  130.00, 6),
    (35, 'Old Skool Platform',       'Vans',        'sneakers',    'goth',          '35-42', 'Black',             90.00,  11),
    (36, 'Slip-On Checkerboard',     'Vans',        'sneakers',    'punk',          '35-45', 'Black/White',       65.00,  15),
    (37, 'Slip-On',                  'Vans',        'sneakers',    'emo',           '35-45', 'Matte Black',       62.00,  16),
    (38, 'Knu Skool',                'Vans',        'sneakers',    'hardcore',      '36-46', 'Black',             85.00,  8),
    (39, 'Sk8-Hi Reissue',           'Vans',        'sneakers',    'metal',         '36-46', 'Black Leather',     100.00, 7),
    (40, 'Half Cab',                 'Vans',        'sneakers',    'hardcore',      '36-45', 'Black/Grey',        88.00,  9)
  ])
) s
ON t.product_id = s.product_id
WHEN NOT MATCHED THEN
  INSERT (product_id, model, brand, type, subculture, size_range, color, price, stock)
  VALUES (s.product_id, s.model, s.brand, s.type, s.subculture, s.size_range, s.color,
          CAST(ROUND(s.price, 2) AS NUMERIC), s.stock);  -- literals are FLOAT64; store exact money

-- ---------------------------------------------------------------- shipping policy
MERGE stride_soul.shipping_policy t
USING (
  SELECT 'shipping_cost' AS topic, 'Shipping is $2.00 per order, and free when you buy 2 pairs or more!' AS content UNION ALL
  SELECT 'delivery_time',  'We deliver within 1 business day inside our metro coverage area.' UNION ALL
  SELECT 'coverage',       'We cover the San Salvador metro area: San Martín, Soyapango, Downtown, San Salvador, Escalón, San Benito, Antiguo Cuscatlán, Merliot, Santa Tecla, Colón (up to Lourdes) and south to Zaragoza.' UNION ALL
  SELECT 'outside_area',   'Outside the metro area? No problem: our courier partner quotes the shipping cost and we confirm the final price before dispatching.' UNION ALL
  SELECT 'store_pickup',   'You can also pick up your order in store at no cost.' UNION ALL
  SELECT 'courier',        'Orders are shipped through our courier partner, which covers the whole metro area.'
) s
ON t.topic = s.topic
WHEN MATCHED THEN UPDATE SET content = s.content
WHEN NOT MATCHED THEN INSERT (topic, content) VALUES (s.topic, s.content);

-- ---------------------------------------------------------------- return policy
MERGE stride_soul.return_policy t
USING (
  SELECT 'window' AS topic, 'You have 14 days from delivery to request an exchange.' AS content UNION ALL
  SELECT 'conditions',          'To process an exchange, the shoes must be unworn, in their original box, and you need the receipt number from your ticket.' UNION ALL
  SELECT 'default_offer',       'Happy to help! Our policy is to take the shoes back and exchange them. If the new pair costs more, you pay the difference; if it costs less, we keep the balance as store credit for you.' UNION ALL
  SELECT 'sale_items',          'Yes, sale and clearance items can be exchanged too, under the same conditions (unworn, original box, receipt number).' UNION ALL
  SELECT 'online_orders',       'If you bought online or by chat and could not try the shoes on, the same 14-day window and conditions apply.' UNION ALL
  SELECT 'manufacturing_defect','If your shoes have a manufacturing defect, tell us and we will check them. A defective pair is exchanged for the same or another pair; refunds follow the terms printed on your receipt.' UNION ALL
  SELECT 'internal_legal_mention',
         '[INTERNAL BEHAVIOUR, never quote] If the customer mentions a lawsuit, a consumer-protection agency or the police: do not argue the policy. Acknowledge calmly, collect contact details (name plus phone or e-mail plus reason) and open a support case with escalation_type = legal_mention.' UNION ALL
  SELECT 'internal_insistence',
         '[INTERNAL BEHAVIOUR, never quote] Offer the exchange policy warmly. If the customer rejects it and insists for the THIRD time, stop pushing the policy: collect contact details and open a support case with escalation_type = supervisor_request. Never repeat the same answer in a loop.'
) s
ON t.topic = s.topic
WHEN MATCHED THEN UPDATE SET content = s.content
WHEN NOT MATCHED THEN INSERT (topic, content) VALUES (s.topic, s.content);
