-- RFM Segmentation con SQL Server usando percentiles exactos (equivalente a qcut de Python)
-- Clasificación de clientes basada en Recency, Frequency y Monetary

WITH
    -- Filtro y limpieza de datos de ventas
    online_retail
    AS
    (
        SELECT *,
            Quantity * UnitPrice AS Revenue
        -- Ingreso por línea de venta
        FROM dbo.OnlineSales
        WHERE
            InvoiceNo NOT LIKE '%[A-Za-z]%' -- Excluir notas de crédito u órdenes no numéricas
            AND CustomerID IS NOT NULL -- Considerar solo clientes identificables
            AND Quantity > 0 -- Evitar devoluciones o errores
            AND UnitPrice > 0
        -- Precios válidos
    ),

    -- Calcular métricas básicas por cliente
    fm_table
    AS
    (
        SELECT
            CustomerID,
            COUNT(DISTINCT InvoiceNo) AS Frequency, -- Nº de compras únicas (frecuencia)
            SUM(Revenue) AS Monetary
        -- Total gastado (valor monetario)
        FROM online_retail
        GROUP BY CustomerID
    ),

    -- Calcular fechas de última compra y fecha actual
    auxiliary_table_rfm
    AS
    (
        SELECT
            o.CustomerID,
            MAX(InvoiceDate) OVER () AS CurrentDate, -- Última fecha en la base
            MAX(InvoiceDate) OVER (PARTITION BY o.CustomerID) AS LastPurchaseDate,
            fm.Frequency,
            fm.Monetary
        FROM online_retail o
            LEFT JOIN fm_table fm ON fm.CustomerID = o.CustomerID
    ),

    -- Construcción de tabla RFM base
    rfm_table
    AS
    (
        SELECT
            CustomerID,
            DATEDIFF(DAY, LastPurchaseDate, CurrentDate) AS Recency, -- Días desde última compra
            Frequency,
            Monetary
        FROM auxiliary_table_rfm
        GROUP BY CustomerID, LastPurchaseDate, CurrentDate, Frequency, Monetary
    ),

    -- Cálculo de cuantiles exactos (terciles) para cada métrica
    quantiles
    AS
    (
        SELECT DISTINCT
            PERCENTILE_CONT(0.33) WITHIN GROUP (ORDER BY Recency) OVER ()   AS r33,
            PERCENTILE_CONT(0.66) WITHIN GROUP (ORDER BY Recency) OVER ()   AS r66,
            PERCENTILE_CONT(0.33) WITHIN GROUP (ORDER BY Frequency) OVER () AS f33,
            PERCENTILE_CONT(0.66) WITHIN GROUP (ORDER BY Frequency) OVER () AS f66,
            PERCENTILE_CONT(0.33) WITHIN GROUP (ORDER BY Monetary) OVER ()  AS m33,
            PERCENTILE_CONT(0.66) WITHIN GROUP (ORDER BY Monetary) OVER ()  AS m66
        FROM rfm_table
    ),

    -- Asignar scores R, F y M según terciles (emulando qcut)
    scored_rfm
    AS
    (
        SELECT
            r.*,
            q.r33, q.r66, q.f33, q.f66, q.m33, q.m66,

            -- Recency: menor valor es mejor (más reciente)
            CASE
                WHEN r.Recency <= q.r33 THEN 3
                WHEN r.Recency <= q.r66 THEN 2
                ELSE 1
            END AS R_Score,

            -- Frequency: mayor valor es mejor (más compras)
            CASE
                WHEN r.Frequency <= q.f33 THEN 1
                WHEN r.Frequency <= q.f66 THEN 2
                ELSE 3
            END AS F_Score,

            -- Monetary: mayor valor es mejor (más gasto)
            CASE
                WHEN r.Monetary <= q.m33 THEN 1
                WHEN r.Monetary <= q.m66 THEN 2
                ELSE 3
            END AS M_Score

        FROM rfm_table r
        CROSS JOIN quantiles q
        -- Aplicar los mismos cortes a todos los clientes
    )

-- Resultado final: RFM score y segmentación
SELECT
    CustomerID,
    Recency,
    Frequency,
    Monetary,
    R_Score,
    F_Score,
    M_Score,
    CAST(R_Score AS VARCHAR) + CAST(F_Score AS VARCHAR) + CAST(M_Score AS VARCHAR) AS RFM_Score,

    -- Segmentos de cliente según combinación de scores
    CASE
        WHEN R_Score = 3 AND F_Score = 3 AND M_Score = 3 THEN 'VIP Customer'
        WHEN R_Score = 3 AND F_Score >= 2 AND M_Score >= 2 THEN 'Loyal Customer'
        WHEN R_Score = 3 THEN 'New Customer'
        WHEN R_Score = 2 AND F_Score = 3 THEN 'Potential Loyallist'
        WHEN F_Score = 1 AND M_Score = 1 THEN 'At Risk'
        WHEN R_Score = 1 THEN 'Lost Customer'
        ELSE 'Promising Customer'
    END AS Segment
FROM scored_rfm;
