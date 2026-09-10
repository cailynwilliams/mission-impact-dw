/*==============================================================
  MissionImpactDW - Database and schema setup

  Creates the database and the stg, dw, and rpt schemas.
  Run this first, everything else depends on it.
==============================================================*/

USE master;
GO

IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = N'MissionImpactDW')
BEGIN
    CREATE DATABASE MissionImpactDW;
END
GO

ALTER DATABASE MissionImpactDW SET RECOVERY SIMPLE;
GO

USE MissionImpactDW;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'stg')
    EXEC('CREATE SCHEMA stg');
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'dw')
    EXEC('CREATE SCHEMA dw');
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'rpt')
    EXEC('CREATE SCHEMA rpt');
GO

PRINT 'Database and schemas created.';
GO
