CREATE DATABASE IF NOT EXISTS fooddelivery_2026204015
    DEFAULT CHARACTER SET utf8mb4
    DEFAULT COLLATE utf8mb4_0900_ai_ci;

USE fooddelivery_2026204015;

DROP TABLE IF EXISTS eventlog_staging_2026204015;

CREATE TABLE eventlog_staging_2026204015 (
    EventID           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    OrderRequestorID  VARCHAR(16)     NOT NULL,
    OrderID           VARCHAR(16)     NOT NULL,
    PartnerID         VARCHAR(16)     NOT NULL DEFAULT '',
    PINCode           CHAR(6)         NOT NULL,
    Status            VARCHAR(24)     NOT NULL,
    `Timestamp`       DATETIME        NOT NULL,
    PRIMARY KEY (EventID),
    KEY idx_order_time (OrderID, `Timestamp`, EventID),
    KEY idx_status     (Status),
    KEY idx_requestor  (OrderRequestorID)
) ENGINE=InnoDB;

LOAD DATA LOCAL INFILE '/absolute/path/to/delivery_data_100k_expanded_pins.csv'
INTO TABLE eventlog_staging_2026204015
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES  TERMINATED BY '\n'
IGNORE 1 LINES
(OrderRequestorID, OrderID, PartnerID, PINCode, Status, @ts)
SET `Timestamp` = STR_TO_DATE(@ts, '%Y-%m-%d %H:%i:%s');

DROP TABLE IF EXISTS deliverystatistics_2026204015;

CREATE TABLE deliverystatistics_2026204015 (

    PINCode                 CHAR(6)          NOT NULL,
    PartnerID               VARCHAR(16)      NOT NULL,
    MonthofOrder            TINYINT UNSIGNED NOT NULL,
    YearofOrder             SMALLINT UNSIGNED NOT NULL,

    TotalOrders             INT UNSIGNED NOT NULL DEFAULT 0,

    TotalPendingAssignment  INT UNSIGNED NOT NULL DEFAULT 0,
    TotalAccepted           INT UNSIGNED NOT NULL DEFAULT 0,
    TotalHeadingforPickup   INT UNSIGNED NOT NULL DEFAULT 0,
    TotalArrivedatPickup    INT UNSIGNED NOT NULL DEFAULT 0,
    TotalPickedUp           INT UNSIGNED NOT NULL DEFAULT 0,
    TotalOutforDelivery     INT UNSIGNED NOT NULL DEFAULT 0,
    TotalArrivedatDoorStep  INT UNSIGNED NOT NULL DEFAULT 0,
    TotalDelivered          INT UNSIGNED NOT NULL DEFAULT 0,
    TotalDropped            INT UNSIGNED NOT NULL DEFAULT 0,
    TotalDelayedatPickup    INT UNSIGNED NOT NULL DEFAULT 0,
    TotalDeliveryFailed     INT UNSIGNED NOT NULL DEFAULT 0,
    TotalReturningtoStore   INT UNSIGNED NOT NULL DEFAULT 0,
    TotalReturned           INT UNSIGNED NOT NULL DEFAULT 0,
    TotalCancelled          INT UNSIGNED NOT NULL DEFAULT 0,

    TimetoAccept            DECIMAL(10,2) DEFAULT NULL,
    TimetoPickup            DECIMAL(10,2) DEFAULT NULL,
    TimetoArriveatDoorStep  DECIMAL(10,2) DEFAULT NULL,
    TimetoDeliver           DECIMAL(10,2) DEFAULT NULL,

    PRIMARY KEY (PINCode, PartnerID, YearofOrder, MonthofOrder),
    KEY idx_partner_period (PartnerID, YearofOrder, MonthofOrder)
) ENGINE=InnoDB;

DROP TABLE IF EXISTS requestorstatistics_2026204015;

CREATE TABLE requestorstatistics_2026204015 (
    OrderRequestorID        VARCHAR(16)       NOT NULL,
    YearofOrder             SMALLINT UNSIGNED NOT NULL,
    MonthofOrder            TINYINT UNSIGNED  NOT NULL,

    TotalOrdersPlaced       INT UNSIGNED NOT NULL DEFAULT 0,
    TotalDelivered          INT UNSIGNED NOT NULL DEFAULT 0,
    TotalCancelled          INT UNSIGNED NOT NULL DEFAULT 0,
    TotalDeliveryFailed     INT UNSIGNED NOT NULL DEFAULT 0,
    TotalReturned           INT UNSIGNED NOT NULL DEFAULT 0,
    TotalReassigned         INT UNSIGNED NOT NULL DEFAULT 0,

    CancellationRate        DECIMAL(5,2) NOT NULL DEFAULT 0.00,
    FailureRate             DECIMAL(5,2) NOT NULL DEFAULT 0.00,
    FulfilmentRate          DECIMAL(5,2) NOT NULL DEFAULT 0.00,
    ReassignmentRate        DECIMAL(5,2) NOT NULL DEFAULT 0.00,

    AvgTimeToAccept         DECIMAL(10,2) DEFAULT NULL,
    AvgTimeToDeliver        DECIMAL(10,2) DEFAULT NULL,
    WorstTimeToDeliver      INT UNSIGNED  DEFAULT NULL,

    DistinctPINsUsed        SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    DistinctPartnersUsed    SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    MostUsedPIN             CHAR(6)     DEFAULT NULL,
    MostFrequentPartnerID   VARCHAR(16) DEFAULT NULL,

    FirstOrderTimestamp     DATETIME DEFAULT NULL,
    LastOrderTimestamp      DATETIME DEFAULT NULL,

    PRIMARY KEY (OrderRequestorID, YearofOrder, MonthofOrder)
) ENGINE=InnoDB;

DROP PROCEDURE IF EXISTS PopulateDeliveryStatistics_2026204015;

DELIMITER $$

CREATE PROCEDURE PopulateDeliveryStatistics_2026204015()
BEGIN
    DECLARE v_done      INT DEFAULT 0;
    DECLARE v_order     VARCHAR(16);
    DECLARE v_row_ptnr  VARCHAR(16);
    DECLARE v_status    VARCHAR(24);
    DECLARE v_ts        DATETIME;

    DECLARE v_cur_order VARCHAR(16) DEFAULT NULL;
    DECLARE v_attempt   INT      DEFAULT 0;
    DECLARE v_partner   VARCHAR(16) DEFAULT '';
    DECLARE v_first_pa  DATETIME DEFAULT NULL;
    DECLARE v_pa_ts     DATETIME DEFAULT NULL;
    DECLARE v_acc_ts    DATETIME DEFAULT NULL;
    DECLARE v_pick_ts   DATETIME DEFAULT NULL;
    DECLARE v_door_ts   DATETIME DEFAULT NULL;
    DECLARE v_deliv_ts  DATETIME DEFAULT NULL;

    DECLARE cur_events CURSOR FOR
        SELECT s.OrderID, s.PartnerID, s.Status, s.`Timestamp`
        FROM   eventlog_staging_2026204015 s
        WHERE  s.Status IN ('PendingAssignment', 'Accepted', 'PickedUp',
                            'ArrivedatDoorStep', 'Delivered')
        ORDER  BY s.OrderID, s.`Timestamp`, s.EventID;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    TRUNCATE TABLE deliverystatistics_2026204015;

    DROP TEMPORARY TABLE IF EXISTS tmp_order;
    DROP TEMPORARY TABLE IF EXISTS tmp_attempt;
    DROP TEMPORARY TABLE IF EXISTS tmp_event;

    CREATE TEMPORARY TABLE tmp_order (
        OrderID      VARCHAR(16)       NOT NULL,
        PINCode      CHAR(6)           NOT NULL,
        FirstPA      DATETIME          NOT NULL,
        MonthofOrder TINYINT UNSIGNED  NOT NULL,
        YearofOrder  SMALLINT UNSIGNED NOT NULL,
        PRIMARY KEY (OrderID)
    ) ENGINE=InnoDB;

    INSERT INTO tmp_order (OrderID, PINCode, FirstPA, MonthofOrder, YearofOrder)
    SELECT s.OrderID,
           MIN(s.PINCode),
           MIN(CASE WHEN s.Status = 'PendingAssignment' THEN s.`Timestamp` END),
           MONTH(MIN(CASE WHEN s.Status = 'PendingAssignment' THEN s.`Timestamp` END)),
           YEAR (MIN(CASE WHEN s.Status = 'PendingAssignment' THEN s.`Timestamp` END))
    FROM   eventlog_staging_2026204015 s
    GROUP  BY s.OrderID
    HAVING MIN(CASE WHEN s.Status = 'PendingAssignment' THEN s.`Timestamp` END) IS NOT NULL;

    CREATE TEMPORARY TABLE tmp_attempt (
        OrderID                VARCHAR(16) NOT NULL,
        AttemptNo              INT         NOT NULL,
        PartnerID              VARCHAR(16) NOT NULL DEFAULT '',
        TimetoAccept           INT DEFAULT NULL,
        TimetoPickup           INT DEFAULT NULL,
        TimetoArriveatDoorStep INT DEFAULT NULL,
        TimetoDeliver          INT DEFAULT NULL,
        PRIMARY KEY (OrderID, AttemptNo)
    ) ENGINE=InnoDB;

    OPEN cur_events;

    read_loop: LOOP
        FETCH cur_events INTO v_order, v_row_ptnr, v_status, v_ts;

        IF v_done = 1 THEN

            IF v_cur_order IS NOT NULL THEN
                INSERT INTO tmp_attempt
                    (OrderID, AttemptNo, PartnerID, TimetoAccept, TimetoPickup,
                     TimetoArriveatDoorStep, TimetoDeliver)
                VALUES
                    (v_cur_order, v_attempt, v_partner,
                     TIMESTAMPDIFF(MINUTE, v_pa_ts,    v_acc_ts),
                     TIMESTAMPDIFF(MINUTE, v_acc_ts,   v_pick_ts),
                     TIMESTAMPDIFF(MINUTE, v_pick_ts,  v_door_ts),
                     TIMESTAMPDIFF(MINUTE, v_first_pa, v_deliv_ts));
            END IF;
            LEAVE read_loop;
        END IF;

        IF v_status = 'PendingAssignment' THEN

            IF v_cur_order IS NOT NULL THEN
                INSERT INTO tmp_attempt
                    (OrderID, AttemptNo, PartnerID, TimetoAccept, TimetoPickup,
                     TimetoArriveatDoorStep, TimetoDeliver)
                VALUES
                    (v_cur_order, v_attempt, v_partner,
                     TIMESTAMPDIFF(MINUTE, v_pa_ts,    v_acc_ts),
                     TIMESTAMPDIFF(MINUTE, v_acc_ts,   v_pick_ts),
                     TIMESTAMPDIFF(MINUTE, v_pick_ts,  v_door_ts),
                     TIMESTAMPDIFF(MINUTE, v_first_pa, v_deliv_ts));
            END IF;

            IF v_cur_order IS NULL OR v_order <> v_cur_order THEN

                SET v_cur_order = v_order;
                SET v_first_pa  = v_ts;
                SET v_attempt   = 1;
            ELSE

                SET v_attempt   = v_attempt + 1;
            END IF;

            SET v_pa_ts    = v_ts;
            SET v_partner  = '';
            SET v_acc_ts   = NULL;
            SET v_pick_ts  = NULL;
            SET v_door_ts  = NULL;
            SET v_deliv_ts = NULL;

        ELSEIF v_status = 'Accepted' THEN
            SET v_acc_ts  = v_ts;
            SET v_partner = v_row_ptnr;

        ELSEIF v_status = 'PickedUp' THEN
            SET v_pick_ts = v_ts;

        ELSEIF v_status = 'ArrivedatDoorStep' THEN
            SET v_door_ts = v_ts;

        ELSEIF v_status = 'Delivered' THEN
            SET v_deliv_ts = v_ts;
        END IF;
    END LOOP read_loop;

    CLOSE cur_events;

    CREATE TEMPORARY TABLE tmp_event (
        OrderID   VARCHAR(16) NOT NULL,
        AttemptNo INT         NOT NULL,
        Status    VARCHAR(24) NOT NULL,
        KEY idx_oa (OrderID, AttemptNo)
    ) ENGINE=InnoDB;

    INSERT INTO tmp_event (OrderID, AttemptNo, Status)
    SELECT w.OrderID, w.AttemptNo, w.Status
    FROM (
        SELECT s.OrderID,
               s.Status,
               SUM(CASE WHEN s.Status = 'PendingAssignment' THEN 1 ELSE 0 END)
                   OVER (PARTITION BY s.OrderID
                         ORDER BY s.`Timestamp`, s.EventID
                         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS AttemptNo
        FROM eventlog_staging_2026204015 s
    ) w;

    INSERT INTO deliverystatistics_2026204015 (
        PINCode, PartnerID, MonthofOrder, YearofOrder,
        TotalOrders,
        TotalPendingAssignment, TotalAccepted, TotalHeadingforPickup,
        TotalArrivedatPickup, TotalPickedUp, TotalOutforDelivery,
        TotalArrivedatDoorStep, TotalDelivered, TotalDropped,
        TotalDelayedatPickup, TotalDeliveryFailed, TotalReturningtoStore,
        TotalReturned, TotalCancelled)
    SELECT o.PINCode,
           a.PartnerID,
           o.MonthofOrder,
           o.YearofOrder,
           COUNT(DISTINCT e.OrderID),
           SUM(e.Status = 'PendingAssignment'),
           SUM(e.Status = 'Accepted'),
           SUM(e.Status = 'HeadingforPickup'),
           SUM(e.Status = 'ArrivedatPickup'),
           SUM(e.Status = 'PickedUp'),
           SUM(e.Status = 'OutforDelivery'),
           SUM(e.Status = 'ArrivedatDoorStep'),
           SUM(e.Status = 'Delivered'),
           SUM(e.Status = 'Dropped'),
           SUM(e.Status = 'DelayedatPickup'),
           SUM(e.Status = 'DeliveryFailed'),
           SUM(e.Status = 'ReturningtoStore'),
           SUM(e.Status = 'Returned'),
           SUM(e.Status = 'Cancelled')
    FROM   tmp_event   e
    JOIN   tmp_order   o ON o.OrderID = e.OrderID
    JOIN   tmp_attempt a ON a.OrderID = e.OrderID AND a.AttemptNo = e.AttemptNo
    GROUP  BY o.PINCode, a.PartnerID, o.YearofOrder, o.MonthofOrder;

    UPDATE deliverystatistics_2026204015 d
    JOIN (
        SELECT o.PINCode,
               a.PartnerID,
               o.YearofOrder,
               o.MonthofOrder,
               AVG(a.TimetoAccept)           AS TimetoAccept,
               AVG(a.TimetoPickup)           AS TimetoPickup,
               AVG(a.TimetoArriveatDoorStep) AS TimetoArriveatDoorStep,
               AVG(a.TimetoDeliver)          AS TimetoDeliver
        FROM   tmp_attempt a
        JOIN   tmp_order   o ON o.OrderID = a.OrderID
        GROUP  BY o.PINCode, a.PartnerID, o.YearofOrder, o.MonthofOrder
    ) t
      ON  t.PINCode      = d.PINCode
      AND t.PartnerID    = d.PartnerID
      AND t.YearofOrder  = d.YearofOrder
      AND t.MonthofOrder = d.MonthofOrder
    SET d.TimetoAccept           = ROUND(t.TimetoAccept, 2),
        d.TimetoPickup           = ROUND(t.TimetoPickup, 2),
        d.TimetoArriveatDoorStep = ROUND(t.TimetoArriveatDoorStep, 2),
        d.TimetoDeliver          = ROUND(t.TimetoDeliver, 2);

    DROP TEMPORARY TABLE IF EXISTS tmp_order;
    DROP TEMPORARY TABLE IF EXISTS tmp_attempt;
    DROP TEMPORARY TABLE IF EXISTS tmp_event;
END$$

DELIMITER ;

DROP PROCEDURE IF EXISTS PopulateRequestorStatistics_2026204015;

DELIMITER $$

CREATE PROCEDURE PopulateRequestorStatistics_2026204015()
BEGIN
    TRUNCATE TABLE requestorstatistics_2026204015;

    DROP TEMPORARY TABLE IF EXISTS tmp_req_order;
    DROP TEMPORARY TABLE IF EXISTS tmp_req_accept;
    DROP TEMPORARY TABLE IF EXISTS tmp_req_pin;
    DROP TEMPORARY TABLE IF EXISTS tmp_req_partner;

    CREATE TEMPORARY TABLE tmp_req_order (
        OrderID          VARCHAR(16)       NOT NULL,
        OrderRequestorID VARCHAR(16)       NOT NULL,
        PINCode          CHAR(6)           NOT NULL,
        YearofOrder      SMALLINT UNSIGNED NOT NULL,
        MonthofOrder     TINYINT UNSIGNED  NOT NULL,
        FirstPA          DATETIME          NOT NULL,
        PACount          INT               NOT NULL,
        IsDelivered      TINYINT           NOT NULL,
        IsCancelled      TINYINT           NOT NULL,
        IsFailed         TINYINT           NOT NULL,
        IsReturned       TINYINT           NOT NULL,
        DeliverMinutes   INT DEFAULT NULL,
        PRIMARY KEY (OrderID),
        KEY idx_req_period (OrderRequestorID, YearofOrder, MonthofOrder)
    ) ENGINE=InnoDB;

    INSERT INTO tmp_req_order
        (OrderID, OrderRequestorID, PINCode, YearofOrder, MonthofOrder,
         FirstPA, PACount, IsDelivered, IsCancelled, IsFailed, IsReturned,
         DeliverMinutes)
    SELECT s.OrderID,
           MIN(s.OrderRequestorID),
           MIN(s.PINCode),
           YEAR (MIN(CASE WHEN s.Status = 'PendingAssignment' THEN s.`Timestamp` END)),
           MONTH(MIN(CASE WHEN s.Status = 'PendingAssignment' THEN s.`Timestamp` END)),
           MIN(CASE WHEN s.Status = 'PendingAssignment' THEN s.`Timestamp` END),
           SUM(s.Status = 'PendingAssignment'),
           MAX(s.Status = 'Delivered'),
           MAX(s.Status = 'Cancelled'),
           MAX(s.Status = 'DeliveryFailed'),
           MAX(s.Status = 'Returned'),
           TIMESTAMPDIFF(MINUTE,
                MIN(CASE WHEN s.Status = 'PendingAssignment' THEN s.`Timestamp` END),
                MAX(CASE WHEN s.Status = 'Delivered'         THEN s.`Timestamp` END))
    FROM   eventlog_staging_2026204015 s
    GROUP  BY s.OrderID
    HAVING MIN(CASE WHEN s.Status = 'PendingAssignment' THEN s.`Timestamp` END) IS NOT NULL;

    CREATE TEMPORARY TABLE tmp_req_accept (
        OrderID       VARCHAR(16) NOT NULL,
        AcceptMinutes INT         NOT NULL,
        KEY idx_o (OrderID)
    ) ENGINE=InnoDB;

    INSERT INTO tmp_req_accept (OrderID, AcceptMinutes)
    SELECT w.OrderID, TIMESTAMPDIFF(MINUTE, w.CurrentPA, w.`Timestamp`)
    FROM (
        SELECT s.OrderID,
               s.Status,
               s.`Timestamp`,
               MAX(CASE WHEN s.Status = 'PendingAssignment' THEN s.`Timestamp` END)
                   OVER (PARTITION BY s.OrderID
                         ORDER BY s.`Timestamp`, s.EventID
                         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS CurrentPA
        FROM eventlog_staging_2026204015 s
    ) w
    WHERE w.Status = 'Accepted'
      AND w.CurrentPA IS NOT NULL;

    CREATE TEMPORARY TABLE tmp_req_pin (
        OrderRequestorID VARCHAR(16)       NOT NULL,
        YearofOrder      SMALLINT UNSIGNED NOT NULL,
        MonthofOrder     TINYINT UNSIGNED  NOT NULL,
        PINCode          CHAR(6)           NOT NULL,
        PRIMARY KEY (OrderRequestorID, YearofOrder, MonthofOrder)
    ) ENGINE=InnoDB;

    INSERT INTO tmp_req_pin (OrderRequestorID, YearofOrder, MonthofOrder, PINCode)
    SELECT p.OrderRequestorID, p.YearofOrder, p.MonthofOrder, p.PINCode
    FROM (
        SELECT o.OrderRequestorID, o.YearofOrder, o.MonthofOrder, o.PINCode,
               ROW_NUMBER() OVER (
                   PARTITION BY o.OrderRequestorID, o.YearofOrder, o.MonthofOrder
                   ORDER BY COUNT(*) DESC, o.PINCode) AS rn
        FROM   tmp_req_order o
        GROUP  BY o.OrderRequestorID, o.YearofOrder, o.MonthofOrder, o.PINCode
    ) p
    WHERE p.rn = 1;

    CREATE TEMPORARY TABLE tmp_req_partner (
        OrderRequestorID  VARCHAR(16)       NOT NULL,
        YearofOrder       SMALLINT UNSIGNED NOT NULL,
        MonthofOrder      TINYINT UNSIGNED  NOT NULL,
        PartnerID         VARCHAR(16)       NOT NULL,
        DistinctPartners  SMALLINT UNSIGNED NOT NULL,
        PRIMARY KEY (OrderRequestorID, YearofOrder, MonthofOrder)
    ) ENGINE=InnoDB;

    INSERT INTO tmp_req_partner
        (OrderRequestorID, YearofOrder, MonthofOrder, PartnerID, DistinctPartners)
    SELECT q.OrderRequestorID, q.YearofOrder, q.MonthofOrder,
           q.PartnerID, q.DistinctPartners
    FROM (
        SELECT o.OrderRequestorID, o.YearofOrder, o.MonthofOrder, e.PartnerID,
               ROW_NUMBER() OVER (
                   PARTITION BY o.OrderRequestorID, o.YearofOrder, o.MonthofOrder
                   ORDER BY COUNT(DISTINCT e.OrderID) DESC, e.PartnerID) AS rn,

               COUNT(*) OVER (
                   PARTITION BY o.OrderRequestorID, o.YearofOrder, o.MonthofOrder
               ) AS DistinctPartners
        FROM   eventlog_staging_2026204015 e
        JOIN   tmp_req_order    o ON o.OrderID = e.OrderID
        WHERE  e.Status = 'Accepted'
        GROUP  BY o.OrderRequestorID, o.YearofOrder, o.MonthofOrder, e.PartnerID
    ) q
    WHERE q.rn = 1;

    INSERT INTO requestorstatistics_2026204015 (
        OrderRequestorID, YearofOrder, MonthofOrder,
        TotalOrdersPlaced, TotalDelivered, TotalCancelled, TotalDeliveryFailed,
        TotalReturned, TotalReassigned,
        CancellationRate, FailureRate, FulfilmentRate, ReassignmentRate,
        AvgTimeToDeliver, WorstTimeToDeliver,
        DistinctPINsUsed, FirstOrderTimestamp, LastOrderTimestamp)
    SELECT o.OrderRequestorID,
           o.YearofOrder,
           o.MonthofOrder,
           COUNT(*),
           SUM(o.IsDelivered),
           SUM(o.IsCancelled),
           SUM(o.IsFailed),
           SUM(o.IsReturned),
           SUM(o.PACount > 1),
           ROUND(100.0 * SUM(o.IsCancelled) / COUNT(*), 2),
           ROUND(100.0 * SUM(o.IsFailed)    / COUNT(*), 2),
           ROUND(100.0 * SUM(o.IsDelivered) / COUNT(*), 2),
           ROUND(100.0 * SUM(o.PACount > 1) / COUNT(*), 2),
           ROUND(AVG(o.DeliverMinutes), 2),
           MAX(o.DeliverMinutes),
           COUNT(DISTINCT o.PINCode),
           MIN(o.FirstPA),
           MAX(o.FirstPA)
    FROM   tmp_req_order o
    GROUP  BY o.OrderRequestorID, o.YearofOrder, o.MonthofOrder;

    UPDATE requestorstatistics_2026204015 r
    JOIN (
        SELECT o.OrderRequestorID, o.YearofOrder, o.MonthofOrder,
               AVG(t.AcceptMinutes) AS AvgAccept
        FROM   tmp_req_accept t
        JOIN   tmp_req_order  o ON o.OrderID = t.OrderID
        GROUP  BY o.OrderRequestorID, o.YearofOrder, o.MonthofOrder
    ) a
      ON  a.OrderRequestorID = r.OrderRequestorID
      AND a.YearofOrder      = r.YearofOrder
      AND a.MonthofOrder     = r.MonthofOrder
    SET r.AvgTimeToAccept = ROUND(a.AvgAccept, 2);

    UPDATE requestorstatistics_2026204015 r
    JOIN   tmp_req_pin p
      ON  p.OrderRequestorID = r.OrderRequestorID
      AND p.YearofOrder      = r.YearofOrder
      AND p.MonthofOrder     = r.MonthofOrder
    SET r.MostUsedPIN = p.PINCode;

    UPDATE requestorstatistics_2026204015 r
    JOIN   tmp_req_partner q
      ON  q.OrderRequestorID = r.OrderRequestorID
      AND q.YearofOrder      = r.YearofOrder
      AND q.MonthofOrder     = r.MonthofOrder
    SET r.MostFrequentPartnerID = q.PartnerID,
        r.DistinctPartnersUsed  = q.DistinctPartners;

    DROP TEMPORARY TABLE IF EXISTS tmp_req_order;
    DROP TEMPORARY TABLE IF EXISTS tmp_req_accept;
    DROP TEMPORARY TABLE IF EXISTS tmp_req_pin;
    DROP TEMPORARY TABLE IF EXISTS tmp_req_partner;
END$$

DELIMITER ;

CALL PopulateDeliveryStatistics_2026204015();
CALL PopulateRequestorStatistics_2026204015();
