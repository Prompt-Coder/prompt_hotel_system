-- prompt_hotel_system
--
-- The script creates this table by itself on first boot when oxmysql is
-- running. You only need this file if your database user is not allowed to
-- CREATE TABLE -- import it once by hand and restart; the script will find it.
--
-- Nothing else in your database is touched.

CREATE TABLE IF NOT EXISTS `prompt_hotel_rentals` (
  `room_id`     VARCHAR(128) NOT NULL,          -- 'prompt_lsmotel:lsmotel:f01_r03'
  `property_id` VARCHAR(96) NOT NULL,
  `identifier`  VARCHAR(64) NOT NULL,          -- citizenid / esx identifier / license
  `renter_name` VARCHAR(64)     NULL,
  `room_type`   VARCHAR(32)     NULL,
  `rented_at`   BIGINT      NOT NULL,          -- unix milliseconds
  `expires_at`  BIGINT      NOT NULL,          -- unix milliseconds
  `guests`      LONGTEXT        NULL,          -- json
  `data`        LONGTEXT        NULL,          -- json, for anything added later
  PRIMARY KEY (`room_id`),
  KEY `idx_prompt_hotel_identifier` (`identifier`),
  KEY `idx_prompt_hotel_expires` (`expires_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
