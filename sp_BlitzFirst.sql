IF OBJECT_ID('dbo.sp_BlitzFirst') IS NULL
  EXEC ('CREATE PROCEDURE dbo.sp_BlitzFirst AS RETURN 0;')
GO


ALTER PROCEDURE [dbo].[sp_BlitzFirst]
    @Question NVARCHAR(MAX) = NULL ,
    @Help TINYINT = 0 ,
    @AsOf DATETIMEOFFSET = NULL ,
    @ExpertMode TINYINT = 0 ,
    @Seconds INT = 5 ,
    @OutputType VARCHAR(20) = 'TABLE' ,
    @OutputServerName NVARCHAR(256) = NULL ,
    @OutputDatabaseName NVARCHAR(256) = NULL ,
    @OutputSchemaName NVARCHAR(256) = NULL ,
    @OutputTableName NVARCHAR(256) = NULL ,
    @OutputTableNameFileStats NVARCHAR(256) = NULL ,
    @OutputTableNamePerfmonStats NVARCHAR(256) = NULL ,
    @OutputTableNameWaitStats NVARCHAR(256) = NULL ,
    @OutputXMLasNVARCHAR TINYINT = 0 ,
    @FilterPlansByDatabase VARCHAR(MAX) = NULL ,
    @CheckProcedureCache TINYINT = 0 ,
    @FileLatencyThresholdMS INT = 100 ,
    @SinceStartup TINYINT = 0 ,
	@ShowSleepingSPIDs TINYINT = 0 ,
    @VersionDate DATETIME = NULL OUTPUT
    WITH EXECUTE AS CALLER, RECOMPILE
AS
BEGIN
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
DECLARE @Version VARCHAR(30);
SET @Version = '5.7';
SET @VersionDate = '20170901';


IF @Help = 1 PRINT '
sp_BlitzFirst from http://FirstResponderKit.org
	
This script gives you a prioritized list of why your SQL Server is slow right now.

This is not an overall health check - for that, check out sp_Blitz.

To learn more, visit http://FirstResponderKit.org where you can download new
versions for free, watch training videos on how it works, get more info on
the findings, contribute your own code, and more.

Known limitations of this version:
 - Only Microsoft-supported versions of SQL Server. Sorry, 2005 and 2000. It
   may work just fine on 2005, and if it does, hug your parents. Just don''t
   file support issues if it breaks.
 - If a temp table called #CustomPerfmonCounters exists for any other session,
   but not our session, this stored proc will fail with an error saying the
   temp table #CustomPerfmonCounters does not exist.
 - @OutputServerName is not functional yet.

Unknown limitations of this version:
 - None. Like Zombo.com, the only limit is yourself.

Changes - for the full list of improvements and fixes in this version, see:
https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit/


MIT License

Copyright (c) 2017 Brent Ozar Unlimited

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

'


RAISERROR('Setting up configuration variables',10,1) WITH NOWAIT;
DECLARE @StringToExecute NVARCHAR(MAX),
    @ParmDefinitions NVARCHAR(4000),
    @Parm1 NVARCHAR(4000),
    @OurSessionID INT,
    @LineFeed NVARCHAR(10),
    @StockWarningHeader NVARCHAR(500),
    @StockWarningFooter NVARCHAR(100),
    @StockDetailsHeader NVARCHAR(100),
    @StockDetailsFooter NVARCHAR(100),
    @StartSampleTime DATETIMEOFFSET,
    @FinishSampleTime DATETIMEOFFSET,
	@FinishSampleTimeWaitFor DATETIME,
    @ServiceName sysname,
    @OutputTableNameFileStats_View NVARCHAR(256),
    @OutputTableNamePerfmonStats_View NVARCHAR(256),
    @OutputTableNameWaitStats_View NVARCHAR(256),
    @OutputTableNameWaitStats_Categories NVARCHAR(256),
    @ObjectFullName NVARCHAR(2000),
	@BlitzWho NVARCHAR(MAX) = N'EXEC dbo.sp_BlitzWho @ShowSleepingSPIDs = ' + CONVERT(NVARCHAR(1), @ShowSleepingSPIDs) + N';';

/* Sanitize our inputs */
SELECT
    @OutputTableNameFileStats_View = QUOTENAME(@OutputTableNameFileStats + '_Deltas'),
    @OutputTableNamePerfmonStats_View = QUOTENAME(@OutputTableNamePerfmonStats + '_Deltas'),
    @OutputTableNameWaitStats_View = QUOTENAME(@OutputTableNameWaitStats + '_Deltas'),
    @OutputTableNameWaitStats_Categories = QUOTENAME(@OutputTableNameWaitStats + '_Categories');

SELECT
    @OutputDatabaseName = QUOTENAME(@OutputDatabaseName),
    @OutputSchemaName = QUOTENAME(@OutputSchemaName),
    @OutputTableName = QUOTENAME(@OutputTableName),
    @OutputTableNameFileStats = QUOTENAME(@OutputTableNameFileStats),
    @OutputTableNamePerfmonStats = QUOTENAME(@OutputTableNamePerfmonStats),
    @OutputTableNameWaitStats = QUOTENAME(@OutputTableNameWaitStats),
    @LineFeed = CHAR(13) + CHAR(10),
    @StartSampleTime = SYSDATETIMEOFFSET(),
    @FinishSampleTime = DATEADD(ss, @Seconds, SYSDATETIMEOFFSET()),
	@FinishSampleTimeWaitFor = DATEADD(ss, @Seconds, GETDATE()),
    @OurSessionID = @@SPID;


IF @SinceStartup = 1
    SELECT @Seconds = 0, @ExpertMode = 1;

IF @Seconds = 0 AND CAST(SERVERPROPERTY('edition') AS VARCHAR(100)) = 'SQL Azure'
    SELECT @StartSampleTime = DATEADD(ms, AVG(-wait_time_ms), SYSDATETIMEOFFSET()), @FinishSampleTime = SYSDATETIMEOFFSET()
        FROM sys.dm_os_wait_stats w
        WHERE wait_type IN ('BROKER_TASK_STOP','DIRTY_PAGE_POLL','HADR_FILESTREAM_IOMGR_IOCOMPLETION','LAZYWRITER_SLEEP',
                            'LOGMGR_QUEUE','REQUEST_FOR_DEADLOCK_SEARCH','XE_DISPATCHER_WAIT','XE_TIMER_EVENT')
ELSE IF @Seconds = 0 AND CAST(SERVERPROPERTY('edition') AS VARCHAR(100)) <> 'SQL Azure'
    SELECT @StartSampleTime = DATEADD(MINUTE,DATEDIFF(MINUTE, GETDATE(), GETUTCDATE()),create_date) , @FinishSampleTime = SYSDATETIMEOFFSET()
        FROM sys.databases
        WHERE database_id = 2;
ELSE
    SELECT @StartSampleTime = SYSDATETIMEOFFSET(), @FinishSampleTime = DATEADD(ss, @Seconds, SYSDATETIMEOFFSET());

IF @OutputType = 'SCHEMA'
BEGIN
    SELECT FieldList = '[Priority] TINYINT, [FindingsGroup] VARCHAR(50), [Finding] VARCHAR(200), [URL] VARCHAR(200), [Details] NVARCHAR(4000), [HowToStopIt] NVARCHAR(MAX), [QueryPlan] XML, [QueryText] NVARCHAR(MAX)'

END
ELSE IF @AsOf IS NOT NULL AND @OutputDatabaseName IS NOT NULL AND @OutputSchemaName IS NOT NULL AND @OutputTableName IS NOT NULL
BEGIN
    /* They want to look into the past. */

        SET @StringToExecute = N' IF EXISTS(SELECT * FROM '
            + @OutputDatabaseName
            + '.INFORMATION_SCHEMA.SCHEMATA WHERE QUOTENAME(SCHEMA_NAME) = '''
            + @OutputSchemaName + ''') SELECT CheckDate, [Priority], [FindingsGroup], [Finding], [URL], CAST([Details] AS [XML]) AS Details,'
            + '[HowToStopIt], [CheckID], [StartTime], [LoginName], [NTUserName], [OriginalLoginName], [ProgramName], [HostName], [DatabaseID],'
            + '[DatabaseName], [OpenTransactionCount], [QueryPlan], [QueryText] FROM '
            + @OutputDatabaseName + '.'
            + @OutputSchemaName + '.'
            + @OutputTableName
            + ' WHERE CheckDate >= DATEADD(mi, -15, ''' + CAST(@AsOf AS NVARCHAR(100)) + ''')'
            + ' AND CheckDate <= DATEADD(mi, 15, ''' + CAST(@AsOf AS NVARCHAR(100)) + ''')'
            + ' /*ORDER BY CheckDate, Priority , FindingsGroup , Finding , Details*/;';
        EXEC(@StringToExecute);


END /* IF @AsOf IS NOT NULL AND @OutputDatabaseName IS NOT NULL AND @OutputSchemaName IS NOT NULL AND @OutputTableName IS NOT NULL */
ELSE IF @Question IS NULL /* IF @OutputType = 'SCHEMA' */
BEGIN
    /* What's running right now? This is the first and last result set. */
    IF @SinceStartup = 0 AND @Seconds > 0 AND @ExpertMode = 1 
    BEGIN
		IF OBJECT_ID('master.dbo.sp_BlitzWho') IS NULL AND OBJECT_ID('dbo.sp_BlitzWho') IS NULL
		BEGIN
			PRINT N'sp_BlitzWho is not installed in the current database_files.  You can get a copy from http://FirstResponderKit.org'
		END
		ELSE
		BEGIN
			EXEC (@BlitzWho)
		END
    END /* IF @SinceStartup = 0 AND @Seconds > 0 AND @ExpertMode = 1   -   What's running right now? This is the first and last result set. */
     

    RAISERROR('Now starting diagnostic analysis',10,1) WITH NOWAIT;

    /*
    We start by creating #BlitzFirstResults. It's a temp table that will store
    the results from our checks. Throughout the rest of this stored procedure,
    we're running a series of checks looking for dangerous things inside the SQL
    Server. When we find a problem, we insert rows into #BlitzResults. At the
    end, we return these results to the end user.

    #BlitzFirstResults has a CheckID field, but there's no Check table. As we do
    checks, we insert data into this table, and we manually put in the CheckID.
    We (Brent Ozar Unlimited) maintain a list of the checks by ID#. You can
    download that from http://FirstResponderKit.org if you want to build
    a tool that relies on the output of sp_BlitzFirst.
    */

    IF OBJECT_ID('tempdb..#BlitzFirstResults') IS NOT NULL
        DROP TABLE #BlitzFirstResults;
    CREATE TABLE #BlitzFirstResults
        (
          ID INT IDENTITY(1, 1) PRIMARY KEY CLUSTERED,
          CheckID INT NOT NULL,
          Priority TINYINT NOT NULL,
          FindingsGroup VARCHAR(50) NOT NULL,
          Finding VARCHAR(200) NOT NULL,
          URL VARCHAR(200) NULL,
          Details NVARCHAR(4000) NULL,
          HowToStopIt NVARCHAR(MAX) NULL,
          QueryPlan [XML] NULL,
          QueryText NVARCHAR(MAX) NULL,
          StartTime DATETIMEOFFSET NULL,
          LoginName NVARCHAR(128) NULL,
          NTUserName NVARCHAR(128) NULL,
          OriginalLoginName NVARCHAR(128) NULL,
          ProgramName NVARCHAR(128) NULL,
          HostName NVARCHAR(128) NULL,
          DatabaseID INT NULL,
          DatabaseName NVARCHAR(128) NULL,
          OpenTransactionCount INT NULL,
          QueryStatsNowID INT NULL,
          QueryStatsFirstID INT NULL,
          PlanHandle VARBINARY(64) NULL,
          DetailsInt INT NULL,
        );

    IF OBJECT_ID('tempdb..#WaitStats') IS NOT NULL
        DROP TABLE #WaitStats;
    CREATE TABLE #WaitStats (Pass TINYINT NOT NULL, wait_type NVARCHAR(60), wait_time_ms BIGINT, signal_wait_time_ms BIGINT, waiting_tasks_count BIGINT, SampleTime DATETIMEOFFSET);

    IF OBJECT_ID('tempdb..#FileStats') IS NOT NULL
        DROP TABLE #FileStats;
    CREATE TABLE #FileStats (
        ID INT IDENTITY(1, 1) PRIMARY KEY CLUSTERED,
        Pass TINYINT NOT NULL,
        SampleTime DATETIMEOFFSET NOT NULL,
        DatabaseID INT NOT NULL,
        FileID INT NOT NULL,
        DatabaseName NVARCHAR(256) ,
        FileLogicalName NVARCHAR(256) ,
        TypeDesc NVARCHAR(60) ,
        SizeOnDiskMB BIGINT ,
        io_stall_read_ms BIGINT ,
        num_of_reads BIGINT ,
        bytes_read BIGINT ,
        io_stall_write_ms BIGINT ,
        num_of_writes BIGINT ,
        bytes_written BIGINT,
        PhysicalName NVARCHAR(520) ,
        avg_stall_read_ms INT ,
        avg_stall_write_ms INT
    );

    IF OBJECT_ID('tempdb..#QueryStats') IS NOT NULL
        DROP TABLE #QueryStats;
    CREATE TABLE #QueryStats (
        ID INT IDENTITY(1, 1) PRIMARY KEY CLUSTERED,
        Pass INT NOT NULL,
        SampleTime DATETIMEOFFSET NOT NULL,
        [sql_handle] VARBINARY(64),
        statement_start_offset INT,
        statement_end_offset INT,
        plan_generation_num BIGINT,
        plan_handle VARBINARY(64),
        execution_count BIGINT,
        total_worker_time BIGINT,
        total_physical_reads BIGINT,
        total_logical_writes BIGINT,
        total_logical_reads BIGINT,
        total_clr_time BIGINT,
        total_elapsed_time BIGINT,
        creation_time DATETIMEOFFSET,
        query_hash BINARY(8),
        query_plan_hash BINARY(8),
        Points TINYINT
    );

    IF OBJECT_ID('tempdb..#PerfmonStats') IS NOT NULL
        DROP TABLE #PerfmonStats;
    CREATE TABLE #PerfmonStats (
        ID INT IDENTITY(1, 1) PRIMARY KEY CLUSTERED,
        Pass TINYINT NOT NULL,
        SampleTime DATETIMEOFFSET NOT NULL,
        [object_name] NVARCHAR(128) NOT NULL,
        [counter_name] NVARCHAR(128) NOT NULL,
        [instance_name] NVARCHAR(128) NULL,
        [cntr_value] BIGINT NULL,
        [cntr_type] INT NOT NULL,
        [value_delta] BIGINT NULL,
        [value_per_second] DECIMAL(18,2) NULL
    );

    IF OBJECT_ID('tempdb..#PerfmonCounters') IS NOT NULL
        DROP TABLE #PerfmonCounters;
    CREATE TABLE #PerfmonCounters (
        ID INT IDENTITY(1, 1) PRIMARY KEY CLUSTERED,
        [object_name] NVARCHAR(128) NOT NULL,
        [counter_name] NVARCHAR(128) NOT NULL,
        [instance_name] NVARCHAR(128) NULL
    );

    IF OBJECT_ID('tempdb..#FilterPlansByDatabase') IS NOT NULL
        DROP TABLE #FilterPlansByDatabase;
    CREATE TABLE #FilterPlansByDatabase (DatabaseID INT PRIMARY KEY CLUSTERED);

    IF OBJECT_ID('tempdb..##WaitCategories') IS NULL
		BEGIN
			/* We reuse this one by default rather than recreate it every time. */
			CREATE TABLE ##WaitCategories
			(
				WaitType NVARCHAR(60) PRIMARY KEY CLUSTERED,
				WaitCategory NVARCHAR(128) NOT NULL
			);
		END /* IF OBJECT_ID('tempdb..##WaitCategories') IS NULL */

	IF 504 <> (SELECT COALESCE(SUM(1),0) FROM ##WaitCategories)
		BEGIN
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('ASYNC_IO_COMPLETION','Other Disk IO');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('ASYNC_NETWORK_IO','Network IO');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('BACKUPIO','Other Disk IO');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('BROKER_CONNECTION_RECEIVE_TASK','Service Broker');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('BROKER_DISPATCHER','Service Broker');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('BROKER_ENDPOINT_STATE_MUTEX','Service Broker');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('BROKER_EVENTHANDLER','Service Broker');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('BROKER_FORWARDER','Service Broker');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('BROKER_INIT','Service Broker');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('BROKER_MASTERSTART','Service Broker');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('BROKER_RECEIVE_WAITFOR','User Wait');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('BROKER_REGISTERALLENDPOINTS','Service Broker');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('BROKER_SERVICE','Service Broker');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('BROKER_SHUTDOWN','Service Broker');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('BROKER_START','Service Broker');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('BROKER_TASK_SHUTDOWN','Service Broker');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('BROKER_TASK_STOP','Service Broker');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('BROKER_TASK_SUBMIT','Service Broker');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('BROKER_TO_FLUSH','Service Broker');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('BROKER_TRANSMISSION_OBJECT','Service Broker');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('BROKER_TRANSMISSION_TABLE','Service Broker');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('BROKER_TRANSMISSION_WORK','Service Broker');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('BROKER_TRANSMITTER','Service Broker');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('CHECKPOINT_QUEUE','Idle');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('CHKPT','Tran Log IO');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('CLR_AUTO_EVENT','SQL CLR');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('CLR_CRST','SQL CLR');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('CLR_JOIN','SQL CLR');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('CLR_MANUAL_EVENT','SQL CLR');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('CLR_MEMORY_SPY','SQL CLR');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('CLR_MONITOR','SQL CLR');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('CLR_RWLOCK_READER','SQL CLR');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('CLR_RWLOCK_WRITER','SQL CLR');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('CLR_SEMAPHORE','SQL CLR');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('CLR_TASK_START','SQL CLR');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('CLRHOST_STATE_ACCESS','SQL CLR');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('CMEMPARTITIONED','Memory');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('CMEMTHREAD','Memory');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('CXPACKET','Parallelism');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('DBMIRROR_DBM_EVENT','Mirroring');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('DBMIRROR_DBM_MUTEX','Mirroring');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('DBMIRROR_EVENTS_QUEUE','Mirroring');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('DBMIRROR_SEND','Mirroring');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('DBMIRROR_WORKER_QUEUE','Mirroring');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('DBMIRRORING_CMD','Mirroring');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('DTC','Transaction');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('DTC_ABORT_REQUEST','Transaction');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('DTC_RESOLVE','Transaction');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('DTC_STATE','Transaction');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('DTC_TMDOWN_REQUEST','Transaction');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('DTC_WAITFOR_OUTCOME','Transaction');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('DTCNEW_ENLIST','Transaction');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('DTCNEW_PREPARE','Transaction');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('DTCNEW_RECOVERY','Transaction');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('DTCNEW_TM','Transaction');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('DTCNEW_TRANSACTION_ENLISTMENT','Transaction');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('DTCPNTSYNC','Transaction');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('EE_PMOLOCK','Memory');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('EXCHANGE','Parallelism');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('EXTERNAL_SCRIPT_NETWORK_IOF','Network IO');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('FCB_REPLICA_READ','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('FCB_REPLICA_WRITE','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('FT_COMPROWSET_RWLOCK','Full Text Search');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('FT_IFTS_RWLOCK','Full Text Search');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('FT_IFTS_SCHEDULER_IDLE_WAIT','Idle');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('FT_IFTSHC_MUTEX','Full Text Search');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('FT_IFTSISM_MUTEX','Full Text Search');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('FT_MASTER_MERGE','Full Text Search');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('FT_MASTER_MERGE_COORDINATOR','Full Text Search');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('FT_METADATA_MUTEX','Full Text Search');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('FT_PROPERTYLIST_CACHE','Full Text Search');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('FT_RESTART_CRAWL','Full Text Search');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('FULLTEXT GATHERER','Full Text Search');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_AG_MUTEX','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_AR_CRITICAL_SECTION_ENTRY','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_AR_MANAGER_MUTEX','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_AR_UNLOAD_COMPLETED','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_ARCONTROLLER_NOTIFICATIONS_SUBSCRIBER_LIST','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_BACKUP_BULK_LOCK','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_BACKUP_QUEUE','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_CLUSAPI_CALL','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_COMPRESSED_CACHE_SYNC','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_CONNECTIVITY_INFO','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_DATABASE_FLOW_CONTROL','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_DATABASE_VERSIONING_STATE','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_DATABASE_WAIT_FOR_RECOVERY','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_DATABASE_WAIT_FOR_RESTART','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_DATABASE_WAIT_FOR_TRANSITION_TO_VERSIONING','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_DB_COMMAND','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_DB_OP_COMPLETION_SYNC','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_DB_OP_START_SYNC','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_DBR_SUBSCRIBER','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_DBR_SUBSCRIBER_FILTER_LIST','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_DBSEEDING','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_DBSEEDING_LIST','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_DBSTATECHANGE_SYNC','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_FABRIC_CALLBACK','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_FILESTREAM_BLOCK_FLUSH','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_FILESTREAM_FILE_CLOSE','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_FILESTREAM_FILE_REQUEST','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_FILESTREAM_IOMGR','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_FILESTREAM_IOMGR_IOCOMPLETION','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_FILESTREAM_MANAGER','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_FILESTREAM_PREPROC','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_GROUP_COMMIT','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_LOGCAPTURE_SYNC','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_LOGCAPTURE_WAIT','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_LOGPROGRESS_SYNC','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_NOTIFICATION_DEQUEUE','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_NOTIFICATION_WORKER_EXCLUSIVE_ACCESS','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_NOTIFICATION_WORKER_STARTUP_SYNC','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_NOTIFICATION_WORKER_TERMINATION_SYNC','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_PARTNER_SYNC','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_READ_ALL_NETWORKS','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_RECOVERY_WAIT_FOR_CONNECTION','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_RECOVERY_WAIT_FOR_UNDO','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_REPLICAINFO_SYNC','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_SEEDING_CANCELLATION','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_SEEDING_FILE_LIST','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_SEEDING_LIMIT_BACKUPS','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_SEEDING_SYNC_COMPLETION','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_SEEDING_TIMEOUT_TASK','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_SEEDING_WAIT_FOR_COMPLETION','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_SYNC_COMMIT','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_SYNCHRONIZING_THROTTLE','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_TDS_LISTENER_SYNC','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_TDS_LISTENER_SYNC_PROCESSING','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_THROTTLE_LOG_RATE_GOVERNOR','Log Rate Governor');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_TIMER_TASK','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_TRANSPORT_DBRLIST','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_TRANSPORT_FLOW_CONTROL','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_TRANSPORT_SESSION','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_WORK_POOL','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_WORK_QUEUE','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('HADR_XRF_STACK_ACCESS','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('INSTANCE_LOG_RATE_GOVERNOR','Log Rate Governor');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('IO_COMPLETION','Other Disk IO');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('IO_QUEUE_LIMIT','Other Disk IO');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('IO_RETRY','Other Disk IO');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LATCH_DT','Latch');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LATCH_EX','Latch');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LATCH_KP','Latch');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LATCH_NL','Latch');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LATCH_SH','Latch');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LATCH_UP','Latch');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LAZYWRITER_SLEEP','Idle');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_BU','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_BU_ABORT_BLOCKERS','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_BU_LOW_PRIORITY','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_IS','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_IS_ABORT_BLOCKERS','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_IS_LOW_PRIORITY','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_IU','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_IU_ABORT_BLOCKERS','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_IU_LOW_PRIORITY','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_IX','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_IX_ABORT_BLOCKERS','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_IX_LOW_PRIORITY','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_RIn_NL','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_RIn_NL_ABORT_BLOCKERS','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_RIn_NL_LOW_PRIORITY','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_RIn_S','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_RIn_S_ABORT_BLOCKERS','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_RIn_S_LOW_PRIORITY','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_RIn_U','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_RIn_U_ABORT_BLOCKERS','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_RIn_U_LOW_PRIORITY','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_RIn_X','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_RIn_X_ABORT_BLOCKERS','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_RIn_X_LOW_PRIORITY','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_RS_S','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_RS_S_ABORT_BLOCKERS','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_RS_S_LOW_PRIORITY','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_RS_U','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_RS_U_ABORT_BLOCKERS','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_RS_U_LOW_PRIORITY','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_RX_S','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_RX_S_ABORT_BLOCKERS','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_RX_S_LOW_PRIORITY','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_RX_U','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_RX_U_ABORT_BLOCKERS','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_RX_U_LOW_PRIORITY','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_RX_X','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_RX_X_ABORT_BLOCKERS','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_RX_X_LOW_PRIORITY','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_S','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_S_ABORT_BLOCKERS','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_S_LOW_PRIORITY','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_SCH_M','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_SCH_M_ABORT_BLOCKERS','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_SCH_M_LOW_PRIORITY','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_SCH_S','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_SCH_S_ABORT_BLOCKERS','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_SCH_S_LOW_PRIORITY','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_SIU','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_SIU_ABORT_BLOCKERS','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_SIU_LOW_PRIORITY','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_SIX','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_SIX_ABORT_BLOCKERS','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_SIX_LOW_PRIORITY','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_U','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_U_ABORT_BLOCKERS','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_U_LOW_PRIORITY','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_UIX','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_UIX_ABORT_BLOCKERS','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_UIX_LOW_PRIORITY','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_X','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_X_ABORT_BLOCKERS','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LCK_M_X_LOW_PRIORITY','Lock');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LOGBUFFER','Tran Log IO');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LOGMGR','Tran Log IO');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LOGMGR_FLUSH','Tran Log IO');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LOGMGR_PMM_LOG','Tran Log IO');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LOGMGR_QUEUE','Idle');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('LOGMGR_RESERVE_APPEND','Tran Log IO');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('MEMORY_ALLOCATION_EXT','Memory');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('MEMORY_GRANT_UPDATE','Memory');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('MSQL_XACT_MGR_MUTEX','Transaction');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('MSQL_XACT_MUTEX','Transaction');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('MSSEARCH','Full Text Search');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('NET_WAITFOR_PACKET','Network IO');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('ONDEMAND_TASK_QUEUE','Idle');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PAGEIOLATCH_DT','Buffer IO');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PAGEIOLATCH_EX','Buffer IO');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PAGEIOLATCH_KP','Buffer IO');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PAGEIOLATCH_NL','Buffer IO');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PAGEIOLATCH_SH','Buffer IO');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PAGEIOLATCH_UP','Buffer IO');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PAGELATCH_DT','Buffer Latch');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PAGELATCH_EX','Buffer Latch');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PAGELATCH_KP','Buffer Latch');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PAGELATCH_NL','Buffer Latch');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PAGELATCH_SH','Buffer Latch');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PAGELATCH_UP','Buffer Latch');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('POOL_LOG_RATE_GOVERNOR','Log Rate Governor');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_ABR','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_CLOSEBACKUPMEDIA','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_CLOSEBACKUPTAPE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_CLOSEBACKUPVDIDEVICE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_CLUSAPI_CLUSTERRESOURCECONTROL','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_COCREATEINSTANCE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_COGETCLASSOBJECT','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_CREATEACCESSOR','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_DELETEROWS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_GETCOMMANDTEXT','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_GETDATA','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_GETNEXTROWS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_GETRESULT','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_GETROWSBYBOOKMARK','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_LBFLUSH','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_LBLOCKREGION','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_LBREADAT','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_LBSETSIZE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_LBSTAT','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_LBUNLOCKREGION','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_LBWRITEAT','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_QUERYINTERFACE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_RELEASE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_RELEASEACCESSOR','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_RELEASEROWS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_RELEASESESSION','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_RESTARTPOSITION','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_SEQSTRMREAD','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_SEQSTRMREADANDWRITE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_SETDATAFAILURE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_SETPARAMETERINFO','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_SETPARAMETERPROPERTIES','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_STRMLOCKREGION','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_STRMSEEKANDREAD','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_STRMSEEKANDWRITE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_STRMSETSIZE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_STRMSTAT','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_COM_STRMUNLOCKREGION','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_CONSOLEWRITE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_CREATEPARAM','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_DEBUG','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_DFSADDLINK','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_DFSLINKEXISTCHECK','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_DFSLINKHEALTHCHECK','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_DFSREMOVELINK','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_DFSREMOVEROOT','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_DFSROOTFOLDERCHECK','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_DFSROOTINIT','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_DFSROOTSHARECHECK','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_DTC_ABORT','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_DTC_ABORTREQUESTDONE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_DTC_BEGINTRANSACTION','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_DTC_COMMITREQUESTDONE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_DTC_ENLIST','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_DTC_PREPAREREQUESTDONE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_FILESIZEGET','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_FSAOLEDB_ABORTTRANSACTION','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_FSAOLEDB_COMMITTRANSACTION','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_FSAOLEDB_STARTTRANSACTION','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_FSRECOVER_UNCONDITIONALUNDO','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_GETRMINFO','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_HADR_LEASE_MECHANISM','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_HTTP_EVENT_WAIT','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_HTTP_REQUEST','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_LOCKMONITOR','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_MSS_RELEASE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_ODBCOPS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OLE_UNINIT','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OLEDB_ABORTORCOMMITTRAN','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OLEDB_ABORTTRAN','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OLEDB_GETDATASOURCE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OLEDB_GETLITERALINFO','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OLEDB_GETPROPERTIES','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OLEDB_GETPROPERTYINFO','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OLEDB_GETSCHEMALOCK','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OLEDB_JOINTRANSACTION','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OLEDB_RELEASE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OLEDB_SETPROPERTIES','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OLEDBOPS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_ACCEPTSECURITYCONTEXT','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_ACQUIRECREDENTIALSHANDLE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_AUTHENTICATIONOPS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_AUTHORIZATIONOPS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_AUTHZGETINFORMATIONFROMCONTEXT','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_AUTHZINITIALIZECONTEXTFROMSID','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_AUTHZINITIALIZERESOURCEMANAGER','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_BACKUPREAD','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_CLOSEHANDLE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_CLUSTEROPS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_COMOPS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_COMPLETEAUTHTOKEN','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_COPYFILE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_CREATEDIRECTORY','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_CREATEFILE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_CRYPTACQUIRECONTEXT','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_CRYPTIMPORTKEY','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_CRYPTOPS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_DECRYPTMESSAGE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_DELETEFILE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_DELETESECURITYCONTEXT','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_DEVICEIOCONTROL','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_DEVICEOPS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_DIRSVC_NETWORKOPS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_DISCONNECTNAMEDPIPE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_DOMAINSERVICESOPS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_DSGETDCNAME','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_DTCOPS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_ENCRYPTMESSAGE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_FILEOPS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_FINDFILE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_FLUSHFILEBUFFERS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_FORMATMESSAGE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_FREECREDENTIALSHANDLE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_FREELIBRARY','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_GENERICOPS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_GETADDRINFO','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_GETCOMPRESSEDFILESIZE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_GETDISKFREESPACE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_GETFILEATTRIBUTES','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_GETFILESIZE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_GETFINALFILEPATHBYHANDLE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_GETLONGPATHNAME','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_GETPROCADDRESS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_GETVOLUMENAMEFORVOLUMEMOUNTPOINT','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_GETVOLUMEPATHNAME','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_INITIALIZESECURITYCONTEXT','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_LIBRARYOPS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_LOADLIBRARY','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_LOGONUSER','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_LOOKUPACCOUNTSID','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_MESSAGEQUEUEOPS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_MOVEFILE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_NETGROUPGETUSERS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_NETLOCALGROUPGETMEMBERS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_NETUSERGETGROUPS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_NETUSERGETLOCALGROUPS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_NETUSERMODALSGET','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_NETVALIDATEPASSWORDPOLICY','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_NETVALIDATEPASSWORDPOLICYFREE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_OPENDIRECTORY','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_PDH_WMI_INIT','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_PIPEOPS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_PROCESSOPS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_QUERYCONTEXTATTRIBUTES','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_QUERYREGISTRY','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_QUERYSECURITYCONTEXTTOKEN','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_REMOVEDIRECTORY','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_REPORTEVENT','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_REVERTTOSELF','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_RSFXDEVICEOPS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_SECURITYOPS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_SERVICEOPS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_SETENDOFFILE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_SETFILEPOINTER','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_SETFILEVALIDDATA','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_SETNAMEDSECURITYINFO','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_SQLCLROPS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_SQMLAUNCH','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_VERIFYSIGNATURE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_VERIFYTRUST','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_VSSOPS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_WAITFORSINGLEOBJECT','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_WINSOCKOPS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_WRITEFILE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_WRITEFILEGATHER','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_OS_WSASETLASTERROR','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_REENLIST','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_RESIZELOG','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_ROLLFORWARDREDO','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_ROLLFORWARDUNDO','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_SB_STOPENDPOINT','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_SERVER_STARTUP','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_SETRMINFO','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_SHAREDMEM_GETDATA','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_SNIOPEN','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_SOSHOST','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_SOSTESTING','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_SP_SERVER_DIAGNOSTICS','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_STARTRM','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_STREAMFCB_CHECKPOINT','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_STREAMFCB_RECOVER','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_STRESSDRIVER','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_TESTING','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_TRANSIMPORT','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_UNMARSHALPROPAGATIONTOKEN','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_VSS_CREATESNAPSHOT','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_VSS_CREATEVOLUMESNAPSHOT','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_XE_CALLBACKEXECUTE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_XE_CX_FILE_OPEN','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_XE_CX_HTTP_CALL','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_XE_DISPATCHER','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_XE_ENGINEINIT','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_XE_GETTARGETSTATE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_XE_SESSIONCOMMIT','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_XE_TARGETFINALIZE','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_XE_TARGETINIT','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_XE_TIMERRUN','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PREEMPTIVE_XETESTING','Preemptive');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PWAIT_HADR_ACTION_COMPLETED','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PWAIT_HADR_CHANGE_NOTIFIER_TERMINATION_SYNC','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PWAIT_HADR_CLUSTER_INTEGRATION','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PWAIT_HADR_FAILOVER_COMPLETED','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PWAIT_HADR_JOIN','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PWAIT_HADR_OFFLINE_COMPLETED','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PWAIT_HADR_ONLINE_COMPLETED','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PWAIT_HADR_POST_ONLINE_COMPLETED','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PWAIT_HADR_SERVER_READY_CONNECTIONS','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PWAIT_HADR_WORKITEM_COMPLETED','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PWAIT_HADRSIM','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('PWAIT_RESOURCE_SEMAPHORE_FT_PARALLEL_QUERY_SYNC','Full Text Search');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('QUERY_TRACEOUT','Tracing');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('REPL_CACHE_ACCESS','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('REPL_HISTORYCACHE_ACCESS','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('REPL_SCHEMA_ACCESS','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('REPL_TRANFSINFO_ACCESS','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('REPL_TRANHASHTABLE_ACCESS','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('REPL_TRANTEXTINFO_ACCESS','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('REPLICA_WRITES','Replication');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('REQUEST_FOR_DEADLOCK_SEARCH','Idle');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('RESERVED_MEMORY_ALLOCATION_EXT','Memory');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('RESOURCE_SEMAPHORE','Memory');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('RESOURCE_SEMAPHORE_QUERY_COMPILE','Compilation');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('SLEEP_BPOOL_FLUSH','Idle');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('SLEEP_BUFFERPOOL_HELPLW','Idle');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('SLEEP_DBSTARTUP','Idle');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('SLEEP_DCOMSTARTUP','Idle');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('SLEEP_MASTERDBREADY','Idle');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('SLEEP_MASTERMDREADY','Idle');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('SLEEP_MASTERUPGRADED','Idle');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('SLEEP_MEMORYPOOL_ALLOCATEPAGES','Idle');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('SLEEP_MSDBSTARTUP','Idle');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('SLEEP_RETRY_VIRTUALALLOC','Idle');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('SLEEP_SYSTEMTASK','Idle');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('SLEEP_TASK','Idle');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('SLEEP_TEMPDBSTARTUP','Idle');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('SLEEP_WORKSPACE_ALLOCATEPAGE','Idle');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('SOS_SCHEDULER_YIELD','CPU');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('SQLCLR_APPDOMAIN','SQL CLR');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('SQLCLR_ASSEMBLY','SQL CLR');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('SQLCLR_DEADLOCK_DETECTION','SQL CLR');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('SQLCLR_QUANTUM_PUNISHMENT','SQL CLR');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('SQLTRACE_BUFFER_FLUSH','Idle');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('SQLTRACE_FILE_BUFFER','Tracing');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('SQLTRACE_FILE_READ_IO_COMPLETION','Tracing');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('SQLTRACE_FILE_WRITE_IO_COMPLETION','Tracing');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('SQLTRACE_INCREMENTAL_FLUSH_SLEEP','Idle');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('SQLTRACE_PENDING_BUFFER_WRITERS','Tracing');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('SQLTRACE_SHUTDOWN','Tracing');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('SQLTRACE_WAIT_ENTRIES','Idle');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('THREADPOOL','Worker Thread');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('TRACE_EVTNOTIF','Tracing');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('TRACEWRITE','Tracing');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('TRAN_MARKLATCH_DT','Transaction');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('TRAN_MARKLATCH_EX','Transaction');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('TRAN_MARKLATCH_KP','Transaction');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('TRAN_MARKLATCH_NL','Transaction');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('TRAN_MARKLATCH_SH','Transaction');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('TRAN_MARKLATCH_UP','Transaction');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('TRANSACTION_MUTEX','Transaction');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('WAIT_FOR_RESULTS','User Wait');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('WAITFOR','User Wait');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('WRITE_COMPLETION','Other Disk IO');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('WRITELOG','Tran Log IO');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('XACT_OWN_TRANSACTION','Transaction');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('XACT_RECLAIM_SESSION','Transaction');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('XACTLOCKINFO','Transaction');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('XACTWORKSPACE_MUTEX','Transaction');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('XE_DISPATCHER_WAIT','Idle');
			INSERT INTO ##WaitCategories(WaitType, WaitCategory) VALUES ('XE_TIMER_EVENT','Idle');
		END /* IF SELECT SUM(1) FROM ##WaitCategories <> 504 */



    IF OBJECT_ID('tempdb..#MasterFiles') IS NOT NULL
        DROP TABLE #MasterFiles;
    CREATE TABLE #MasterFiles (database_id INT, file_id INT, type_desc NVARCHAR(50), name NVARCHAR(255), physical_name NVARCHAR(255), size BIGINT);
    /* Azure SQL Database doesn't have sys.master_files, so we have to build our own. */
    IF CAST(SERVERPROPERTY('edition') AS VARCHAR(100)) = 'SQL Azure'
        SET @StringToExecute = 'INSERT INTO #MasterFiles (database_id, file_id, type_desc, name, physical_name, size) SELECT DB_ID(), file_id, type_desc, name, physical_name, size FROM sys.database_files;'
    ELSE
        SET @StringToExecute = 'INSERT INTO #MasterFiles (database_id, file_id, type_desc, name, physical_name, size) SELECT database_id, file_id, type_desc, name, physical_name, size FROM sys.master_files;'
    EXEC(@StringToExecute);

    IF @FilterPlansByDatabase IS NOT NULL
        BEGIN
        IF UPPER(LEFT(@FilterPlansByDatabase,4)) = 'USER'
            BEGIN
            INSERT INTO #FilterPlansByDatabase (DatabaseID)
            SELECT database_id
                FROM sys.databases
                WHERE [name] NOT IN ('master', 'model', 'msdb', 'tempdb')
            END
        ELSE
            BEGIN
            SET @FilterPlansByDatabase = @FilterPlansByDatabase + ','
            ;WITH a AS
                (
                SELECT CAST(1 AS BIGINT) f, CHARINDEX(',', @FilterPlansByDatabase) t, 1 SEQ
                UNION ALL
                SELECT t + 1, CHARINDEX(',', @FilterPlansByDatabase, t + 1), SEQ + 1
                FROM a
                WHERE CHARINDEX(',', @FilterPlansByDatabase, t + 1) > 0
                )
            INSERT #FilterPlansByDatabase (DatabaseID)
                SELECT SUBSTRING(@FilterPlansByDatabase, f, t - f)
                FROM a
                WHERE SUBSTRING(@FilterPlansByDatabase, f, t - f) IS NOT NULL
                OPTION (MAXRECURSION 0)
            END
        END


    SET @StockWarningHeader = '<?ClickToSeeCommmand -- ' + @LineFeed + @LineFeed
        + 'WARNING: Running this command may result in data loss or an outage.' + @LineFeed
        + 'This tool is meant as a shortcut to help generate scripts for DBAs.' + @LineFeed
        + 'It is not a substitute for database training and experience.' + @LineFeed
        + 'Now, having said that, here''s the details:' + @LineFeed + @LineFeed;

    SELECT @StockWarningFooter = @LineFeed + @LineFeed + '-- ?>',
        @StockDetailsHeader = '<?ClickToSeeDetails -- ' + @LineFeed,
        @StockDetailsFooter = @LineFeed + ' -- ?>';

    /* Get the instance name to use as a Perfmon counter prefix. */
    IF CAST(SERVERPROPERTY('edition') AS VARCHAR(100)) = 'SQL Azure'
        SELECT TOP 1 @ServiceName = LEFT(object_name, (CHARINDEX(':', object_name) - 1))
        FROM sys.dm_os_performance_counters;
    ELSE
        BEGIN
        SET @StringToExecute = 'INSERT INTO #PerfmonStats(object_name, Pass, SampleTime, counter_name, cntr_type) SELECT CASE WHEN @@SERVICENAME = ''MSSQLSERVER'' THEN ''SQLServer'' ELSE ''MSSQL$'' + @@SERVICENAME END, 0, SYSDATETIMEOFFSET(), ''stuffing'', 0 ;'
        EXEC(@StringToExecute);
        SELECT @ServiceName = object_name FROM #PerfmonStats;
        DELETE #PerfmonStats;
        END

    /* Build a list of queries that were run in the last 10 seconds.
       We're looking for the death-by-a-thousand-small-cuts scenario
       where a query is constantly running, and it doesn't have that
       big of an impact individually, but it has a ton of impact
       overall. We're going to build this list, and then after we
       finish our @Seconds sample, we'll compare our plan cache to
       this list to see what ran the most. */

    /* Populate #QueryStats. SQL 2005 doesn't have query hash or query plan hash. */
    IF @CheckProcedureCache = 1 
	BEGIN
		RAISERROR('@CheckProcedureCache = 1, capturing first pass of plan cache',10,1) WITH NOWAIT;
		IF @@VERSION LIKE 'Microsoft SQL Server 2005%'
			BEGIN
			IF @FilterPlansByDatabase IS NULL
				BEGIN
				SET @StringToExecute = N'INSERT INTO #QueryStats ([sql_handle], Pass, SampleTime, statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, query_hash, query_plan_hash, Points)
											SELECT [sql_handle], 1 AS Pass, SYSDATETIMEOFFSET(), statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, NULL AS query_hash, NULL AS query_plan_hash, 0
											FROM sys.dm_exec_query_stats qs
											WHERE qs.last_execution_time >= (DATEADD(ss, -10, SYSDATETIMEOFFSET()));';
				END
			ELSE
				BEGIN
				SET @StringToExecute = N'INSERT INTO #QueryStats ([sql_handle], Pass, SampleTime, statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, query_hash, query_plan_hash, Points)
											SELECT [sql_handle], 1 AS Pass, SYSDATETIMEOFFSET(), statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, NULL AS query_hash, NULL AS query_plan_hash, 0
											FROM sys.dm_exec_query_stats qs
												CROSS APPLY sys.dm_exec_plan_attributes(qs.plan_handle) AS attr
												INNER JOIN #FilterPlansByDatabase dbs ON CAST(attr.value AS INT) = dbs.DatabaseID
											WHERE qs.last_execution_time >= (DATEADD(ss, -10, SYSDATETIMEOFFSET()))
												AND attr.attribute = ''dbid'';';
				END
			END
		ELSE
			BEGIN
			IF @FilterPlansByDatabase IS NULL
				BEGIN
				SET @StringToExecute = N'INSERT INTO #QueryStats ([sql_handle], Pass, SampleTime, statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, query_hash, query_plan_hash, Points)
											SELECT [sql_handle], 1 AS Pass, SYSDATETIMEOFFSET(), statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, query_hash, query_plan_hash, 0
											FROM sys.dm_exec_query_stats qs
											WHERE qs.last_execution_time >= (DATEADD(ss, -10, SYSDATETIMEOFFSET()));';
				END
			ELSE
				BEGIN
				SET @StringToExecute = N'INSERT INTO #QueryStats ([sql_handle], Pass, SampleTime, statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, query_hash, query_plan_hash, Points)
											SELECT [sql_handle], 1 AS Pass, SYSDATETIMEOFFSET(), statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, query_hash, query_plan_hash, 0
											FROM sys.dm_exec_query_stats qs
											CROSS APPLY sys.dm_exec_plan_attributes(qs.plan_handle) AS attr
											INNER JOIN #FilterPlansByDatabase dbs ON CAST(attr.value AS INT) = dbs.DatabaseID
											WHERE qs.last_execution_time >= (DATEADD(ss, -10, SYSDATETIMEOFFSET()))
												AND attr.attribute = ''dbid'';';
				END
			END
		EXEC(@StringToExecute);

		/* Get the totals for the entire plan cache */
		INSERT INTO #QueryStats (Pass, SampleTime, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time)
		SELECT -1 AS Pass, SYSDATETIMEOFFSET(), SUM(execution_count), SUM(total_worker_time), SUM(total_physical_reads), SUM(total_logical_writes), SUM(total_logical_reads), SUM(total_clr_time), SUM(total_elapsed_time), MIN(creation_time)
			FROM sys.dm_exec_query_stats qs;
    END /*IF @CheckProcedureCache = 1 */


    IF EXISTS (SELECT *
                    FROM tempdb.sys.all_objects obj
                    INNER JOIN tempdb.sys.all_columns col1 ON obj.object_id = col1.object_id AND col1.name = 'object_name'
                    INNER JOIN tempdb.sys.all_columns col2 ON obj.object_id = col2.object_id AND col2.name = 'counter_name'
                    INNER JOIN tempdb.sys.all_columns col3 ON obj.object_id = col3.object_id AND col3.name = 'instance_name'
                    WHERE obj.name LIKE '%CustomPerfmonCounters%')
        BEGIN
        SET @StringToExecute = 'INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) SELECT [object_name],[counter_name],[instance_name] FROM #CustomPerfmonCounters'
        EXEC(@StringToExecute);
        END
    ELSE
        BEGIN
        /* Add our default Perfmon counters */
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Access Methods','Forwarded Records/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Access Methods','Page compression attempts/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Access Methods','Page Splits/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Access Methods','Skipped Ghosted Records/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Access Methods','Table Lock Escalations/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Access Methods','Worktables Created/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Buffer Manager','Page life expectancy', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Buffer Manager','Page reads/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Buffer Manager','Page writes/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Buffer Manager','Readahead pages/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Buffer Manager','Target pages', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Buffer Manager','Total pages', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Databases','', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Buffer Manager','Active Transactions','_Total')
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Databases','Log Growths', '_Total')
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Databases','Log Shrinks', '_Total')
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Databases','Transactions/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Databases','Write Transactions/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Databases','XTP Memory Used (KB)',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Exec Statistics','Distributed Query', 'Execs in progress')
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Exec Statistics','DTC calls', 'Execs in progress')
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Exec Statistics','Extended Procedures', 'Execs in progress')
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Exec Statistics','OLEDB calls', 'Execs in progress')
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':General Statistics','Active Temp Tables', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':General Statistics','Logins/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':General Statistics','Logouts/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':General Statistics','Mars Deadlocks', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':General Statistics','Processes blocked', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Locks','Number of Deadlocks/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Memory Manager','Memory Grants Pending', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':SQL Errors','Errors/sec', '_Total')
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':SQL Statistics','Batch Requests/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':SQL Statistics','Forced Parameterizations/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':SQL Statistics','Guided plan executions/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':SQL Statistics','SQL Attention rate', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':SQL Statistics','SQL Compilations/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':SQL Statistics','SQL Re-Compilations/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Workload Group Stats','Query optimizations/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Workload Group Stats','Suboptimal plans/sec',NULL)
        /* Below counters added by Jefferson Elias */
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Access Methods','Worktables From Cache Base',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Access Methods','Worktables From Cache Ratio',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Buffer Manager','Database pages',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Buffer Manager','Free pages',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Buffer Manager','Stolen pages',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Memory Manager','Granted Workspace Memory (KB)',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Memory Manager','Maximum Workspace Memory (KB)',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Memory Manager','Target Server Memory (KB)',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Memory Manager','Total Server Memory (KB)',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Buffer Manager','Buffer cache hit ratio',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Buffer Manager','Buffer cache hit ratio base',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Buffer Manager','Checkpoint pages/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Buffer Manager','Free list stalls/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Buffer Manager','Lazy writes/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':SQL Statistics','Auto-Param Attempts/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':SQL Statistics','Failed Auto-Params/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':SQL Statistics','Safe Auto-Params/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':SQL Statistics','Unsafe Auto-Params/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Access Methods','Workfiles Created/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':General Statistics','User Connections',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Latches','Average Latch Wait Time (ms)',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Latches','Average Latch Wait Time Base',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Latches','Latch Waits/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Latches','Total Latch Wait Time (ms)',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Locks','Average Wait Time (ms)',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Locks','Average Wait Time Base',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Locks','Lock Requests/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Locks','Lock Timeouts/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Locks','Lock Wait Time (ms)',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Locks','Lock Waits/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Transactions','Longest Transaction Running Time',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Access Methods','Full Scans/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Access Methods','Index Searches/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Buffer Manager','Page lookups/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':Cursor Manager by Type','Active cursors',NULL)
        /* Below counters are for In-Memory OLTP (Hekaton), which have a different naming convention.
           And yes, they actually hard-coded the version numbers into the counters.
           For why, see: https://connect.microsoft.com/SQLServer/feedback/details/817216/xtp-perfmon-counters-should-appear-under-sql-server-perfmon-counter-group
        */
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES ('SQL Server 2014 XTP Cursors','Expired rows removed/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES ('SQL Server 2014 XTP Cursors','Expired rows touched/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES ('SQL Server 2014 XTP Garbage Collection','Rows processed/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES ('SQL Server 2014 XTP IO Governor','Io Issued/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES ('SQL Server 2014 XTP Phantom Processor','Phantom expired rows touched/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES ('SQL Server 2014 XTP Phantom Processor','Phantom rows touched/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES ('SQL Server 2014 XTP Transaction Log','Log bytes written/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES ('SQL Server 2014 XTP Transaction Log','Log records written/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES ('SQL Server 2014 XTP Transactions','Transactions aborted by user/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES ('SQL Server 2014 XTP Transactions','Transactions aborted/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES ('SQL Server 2014 XTP Transactions','Transactions created/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES ('SQL Server 2016 XTP Cursors','Expired rows removed/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES ('SQL Server 2016 XTP Cursors','Expired rows touched/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES ('SQL Server 2016 XTP Garbage Collection','Rows processed/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES ('SQL Server 2016 XTP IO Governor','Io Issued/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES ('SQL Server 2016 XTP Phantom Processor','Phantom expired rows touched/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES ('SQL Server 2016 XTP Phantom Processor','Phantom rows touched/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES ('SQL Server 2016 XTP Transaction Log','Log bytes written/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES ('SQL Server 2016 XTP Transaction Log','Log records written/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES ('SQL Server 2016 XTP Transactions','Transactions aborted by user/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES ('SQL Server 2016 XTP Transactions','Transactions aborted/sec',NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES ('SQL Server 2016 XTP Transactions','Transactions created/sec',NULL)
        END

    /* Populate #FileStats, #PerfmonStats, #WaitStats with DMV data.
        After we finish doing our checks, we'll take another sample and compare them. */
	RAISERROR('Capturing first pass of wait stats, perfmon counters, file stats',10,1) WITH NOWAIT;
    INSERT #WaitStats(Pass, SampleTime, wait_type, wait_time_ms, signal_wait_time_ms, waiting_tasks_count)
		SELECT 
		x.Pass, 
		x.SampleTime, 
		x.wait_type, 
		SUM(x.sum_wait_time_ms) AS sum_wait_time_ms, 
		SUM(x.sum_signal_wait_time_ms) AS sum_signal_wait_time_ms, 
		SUM(x.sum_waiting_tasks) AS sum_waiting_tasks
		FROM (
		SELECT  
				1 AS Pass,
				CASE @Seconds WHEN 0 THEN @StartSampleTime ELSE SYSDATETIMEOFFSET() END AS SampleTime,
				owt.wait_type,
		        CASE @Seconds WHEN 0 THEN 0 ELSE SUM(owt.wait_duration_ms) OVER (PARTITION BY owt.wait_type, owt.session_id)
					 - CASE WHEN @Seconds = 0 THEN 0 ELSE (@Seconds * 1000) END END AS sum_wait_time_ms,
				0 AS sum_signal_wait_time_ms,
				0 AS sum_waiting_tasks
			FROM    sys.dm_os_waiting_tasks owt
			WHERE owt.session_id > 50
			AND owt.wait_duration_ms >= CASE @Seconds WHEN 0 THEN 0 ELSE @Seconds * 1000 END
		UNION ALL
		SELECT
		       1 AS Pass,
		       CASE @Seconds WHEN 0 THEN @StartSampleTime ELSE SYSDATETIMEOFFSET() END AS SampleTime,
		       os.wait_type,
		       CASE @Seconds WHEN 0 THEN 0 ELSE SUM(os.wait_time_ms) OVER (PARTITION BY os.wait_type) END AS sum_wait_time_ms,
		       CASE @Seconds WHEN 0 THEN 0 ELSE SUM(os.signal_wait_time_ms) OVER (PARTITION BY os.wait_type ) END AS sum_signal_wait_time_ms,
		       CASE @Seconds WHEN 0 THEN 0 ELSE SUM(os.waiting_tasks_count) OVER (PARTITION BY os.wait_type) END AS sum_waiting_tasks
		   FROM sys.dm_os_wait_stats os
		) x
		   WHERE x.wait_type NOT IN (
                  'BROKER_EVENTHANDLER'
                , 'BROKER_RECEIVE_WAITFOR'
                , 'BROKER_TASK_STOP'
                , 'BROKER_TO_FLUSH'
                , 'BROKER_TRANSMITTER'
                , 'CHECKPOINT_QUEUE'
                , 'DBMIRROR_DBM_EVENT'
                , 'DBMIRROR_DBM_MUTEX'
                , 'DBMIRROR_EVENTS_QUEUE'
                , 'DBMIRROR_WORKER_QUEUE'
                , 'DBMIRRORING_CMD'
                , 'DIRTY_PAGE_POLL'
                , 'DISPATCHER_QUEUE_SEMAPHORE'
                , 'FT_IFTS_SCHEDULER_IDLE_WAIT'
                , 'FT_IFTSHC_MUTEX'
                , 'HADR_CLUSAPI_CALL'
                , 'HADR_FILESTREAM_IOMGR_IOCOMPLETION'
                , 'HADR_LOGCAPTURE_WAIT'
                , 'HADR_NOTIFICATION_DEQUEUE'
                , 'HADR_TIMER_TASK'
                , 'HADR_WORK_QUEUE'
                , 'LAZYWRITER_SLEEP'
                , 'LOGMGR_QUEUE'
                , 'ONDEMAND_TASK_QUEUE'
                , 'PREEMPTIVE_HADR_LEASE_MECHANISM'
                , 'PREEMPTIVE_SP_SERVER_DIAGNOSTICS'
                , 'QDS_ASYNC_QUEUE'
                , 'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP'
                , 'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP'
                , 'QDS_SHUTDOWN_QUEUE'
                , 'REDO_THREAD_PENDING_WORK'
                , 'REQUEST_FOR_DEADLOCK_SEARCH'
                , 'SLEEP_SYSTEMTASK'
                , 'SLEEP_TASK'
                , 'SP_SERVER_DIAGNOSTICS_SLEEP'
                , 'SQLTRACE_BUFFER_FLUSH'
                , 'SQLTRACE_INCREMENTAL_FLUSH_SLEEP'
                , 'UCS_SESSION_REGISTRATION'
                , 'WAIT_XTP_OFFLINE_CKPT_NEW_LOG'
                , 'WAITFOR'
                , 'XE_DISPATCHER_WAIT'
                , 'XE_LIVE_TARGET_TVF'
                , 'XE_TIMER_EVENT'
		   )
		GROUP BY x.Pass, x.SampleTime, x.wait_type
		ORDER BY sum_wait_time_ms DESC;


    INSERT INTO #FileStats (Pass, SampleTime, DatabaseID, FileID, DatabaseName, FileLogicalName, SizeOnDiskMB, io_stall_read_ms ,
        num_of_reads, [bytes_read] , io_stall_write_ms,num_of_writes, [bytes_written], PhysicalName, TypeDesc)
    SELECT
        1 AS Pass,
        CASE @Seconds WHEN 0 THEN @StartSampleTime ELSE SYSDATETIMEOFFSET() END AS SampleTime,
        mf.[database_id],
        mf.[file_id],
        DB_NAME(vfs.database_id) AS [db_name],
        mf.name + N' [' + mf.type_desc COLLATE SQL_Latin1_General_CP1_CI_AS + N']' AS file_logical_name ,
        CAST(( ( vfs.size_on_disk_bytes / 1024.0 ) / 1024.0 ) AS INT) AS size_on_disk_mb ,
        CASE @Seconds WHEN 0 THEN 0 ELSE vfs.io_stall_read_ms END ,
        CASE @Seconds WHEN 0 THEN 0 ELSE vfs.num_of_reads END ,
        CASE @Seconds WHEN 0 THEN 0 ELSE vfs.[num_of_bytes_read] END ,
        CASE @Seconds WHEN 0 THEN 0 ELSE vfs.io_stall_write_ms END ,
        CASE @Seconds WHEN 0 THEN 0 ELSE vfs.num_of_writes END ,
        CASE @Seconds WHEN 0 THEN 0 ELSE vfs.[num_of_bytes_written] END ,
        mf.physical_name,
        mf.type_desc
    FROM sys.dm_io_virtual_file_stats (NULL, NULL) AS vfs
    INNER JOIN #MasterFiles AS mf ON vfs.file_id = mf.file_id
        AND vfs.database_id = mf.database_id
    WHERE vfs.num_of_reads > 0
        OR vfs.num_of_writes > 0;

    INSERT INTO #PerfmonStats (Pass, SampleTime, [object_name],[counter_name],[instance_name],[cntr_value],[cntr_type])
    SELECT         1 AS Pass,
        CASE @Seconds WHEN 0 THEN @StartSampleTime ELSE SYSDATETIMEOFFSET() END AS SampleTime, RTRIM(dmv.object_name), RTRIM(dmv.counter_name), RTRIM(dmv.instance_name), CASE @Seconds WHEN 0 THEN 0 ELSE dmv.cntr_value END, dmv.cntr_type
        FROM #PerfmonCounters counters
        INNER JOIN sys.dm_os_performance_counters dmv ON counters.counter_name COLLATE SQL_Latin1_General_CP1_CI_AS = RTRIM(dmv.counter_name) COLLATE SQL_Latin1_General_CP1_CI_AS
            AND counters.[object_name] COLLATE SQL_Latin1_General_CP1_CI_AS = RTRIM(dmv.[object_name]) COLLATE SQL_Latin1_General_CP1_CI_AS
            AND (counters.[instance_name] IS NULL OR counters.[instance_name] COLLATE SQL_Latin1_General_CP1_CI_AS = RTRIM(dmv.[instance_name]) COLLATE SQL_Latin1_General_CP1_CI_AS)

	RAISERROR('Beginning investigatory queries',10,1) WITH NOWAIT;


    /* Maintenance Tasks Running - Backup Running - CheckID 1 */
    IF @Seconds > 0
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt, QueryPlan, StartTime, LoginName, NTUserName, ProgramName, HostName, DatabaseID, DatabaseName, OpenTransactionCount)
    SELECT 1 AS CheckID,
        1 AS Priority,
        'Maintenance Tasks Running' AS FindingGroup,
        'Backup Running' AS Finding,
        'http://www.BrentOzar.com/askbrent/backups/' AS URL,
        'Backup of ' + DB_NAME(db.resource_database_id) + ' database (' + (SELECT CAST(CAST(SUM(size * 8.0 / 1024 / 1024) AS BIGINT) AS NVARCHAR) FROM #MasterFiles WHERE database_id = db.resource_database_id) + 'GB) is ' + CAST(r.percent_complete AS NVARCHAR(100)) + '% complete, has been running since ' + CAST(r.start_time AS NVARCHAR(100)) + '. ' 
		   + CASE WHEN COALESCE(s.nt_user_name, s.login_name) IS NOT NULL THEN (' Login: ' + COALESCE(s.nt_user_name, s.login_name) + ' ') ELSE '' END AS Details,
        'KILL ' + CAST(r.session_id AS NVARCHAR(100)) + ';' AS HowToStopIt,
        pl.query_plan AS QueryPlan,
        r.start_time AS StartTime,
        s.login_name AS LoginName,
        s.nt_user_name AS NTUserName,
        s.[program_name] AS ProgramName,
        s.[host_name] AS HostName,
        db.[resource_database_id] AS DatabaseID,
        DB_NAME(db.resource_database_id) AS DatabaseName,
        0 AS OpenTransactionCount
    FROM sys.dm_exec_requests r
    INNER JOIN sys.dm_exec_connections c ON r.session_id = c.session_id
    INNER JOIN sys.dm_exec_sessions s ON r.session_id = s.session_id
    INNER JOIN (
    SELECT DISTINCT request_session_id, resource_database_id
    FROM    sys.dm_tran_locks
    WHERE resource_type = N'DATABASE'
    AND     request_mode = N'S'
    AND     request_status = N'GRANT'
    AND     request_owner_type = N'SHARED_TRANSACTION_WORKSPACE') AS db ON s.session_id = db.request_session_id
    CROSS APPLY sys.dm_exec_query_plan(r.plan_handle) pl
    WHERE r.command LIKE 'BACKUP%'
	AND r.start_time <= DATEADD(minute, -5, GETDATE());

    /* If there's a backup running, add details explaining how long full backup has been taking in the last month. */
    IF @Seconds > 0 AND CAST(SERVERPROPERTY('edition') AS VARCHAR(100)) <> 'SQL Azure'
    BEGIN
        SET @StringToExecute = 'UPDATE #BlitzFirstResults SET Details = Details + '' Over the last 60 days, the full backup usually takes '' + CAST((SELECT AVG(DATEDIFF(mi, bs.backup_start_date, bs.backup_finish_date)) FROM msdb.dbo.backupset bs WHERE abr.DatabaseName = bs.database_name AND bs.type = ''D'' AND bs.backup_start_date > DATEADD(dd, -60, SYSDATETIMEOFFSET()) AND bs.backup_finish_date IS NOT NULL) AS NVARCHAR(100)) + '' minutes.'' FROM #BlitzFirstResults abr WHERE abr.CheckID = 1 AND EXISTS (SELECT * FROM msdb.dbo.backupset bs WHERE bs.type = ''D'' AND bs.backup_start_date > DATEADD(dd, -60, SYSDATETIMEOFFSET()) AND bs.backup_finish_date IS NOT NULL AND abr.DatabaseName = bs.database_name AND DATEDIFF(mi, bs.backup_start_date, bs.backup_finish_date) > 1)';
        EXEC(@StringToExecute);
    END


    /* Maintenance Tasks Running - DBCC CHECK* Running - CheckID 2 */
    IF @Seconds > 0 AND EXISTS(SELECT * FROM sys.dm_exec_requests WHERE command LIKE 'DBCC%')
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt, QueryPlan, StartTime, LoginName, NTUserName, ProgramName, HostName, DatabaseID, DatabaseName, OpenTransactionCount)
    SELECT 2 AS CheckID,
        1 AS Priority,
        'Maintenance Tasks Running' AS FindingGroup,
        'DBCC CHECK* Running' AS Finding,
        'http://www.BrentOzar.com/askbrent/dbcc/' AS URL,
        'Corruption check of ' + DB_NAME(db.resource_database_id) + ' database (' + (SELECT CAST(CAST(SUM(size * 8.0 / 1024 / 1024) AS BIGINT) AS NVARCHAR) FROM #MasterFiles WHERE database_id = db.resource_database_id) + 'GB) has been running since ' + CAST(r.start_time AS NVARCHAR(100)) + '. ' AS Details,
        'KILL ' + CAST(r.session_id AS NVARCHAR(100)) + ';' AS HowToStopIt,
        pl.query_plan AS QueryPlan,
        r.start_time AS StartTime,
        s.login_name AS LoginName,
        s.nt_user_name AS NTUserName,
        s.[program_name] AS ProgramName,
        s.[host_name] AS HostName,
        db.[resource_database_id] AS DatabaseID,
        DB_NAME(db.resource_database_id) AS DatabaseName,
        0 AS OpenTransactionCount
    FROM sys.dm_exec_requests r
    INNER JOIN sys.dm_exec_connections c ON r.session_id = c.session_id
    INNER JOIN sys.dm_exec_sessions s ON r.session_id = s.session_id
    INNER JOIN (SELECT DISTINCT l.request_session_id, l.resource_database_id
    FROM    sys.dm_tran_locks l
    INNER JOIN sys.databases d ON l.resource_database_id = d.database_id
    WHERE l.resource_type = N'DATABASE'
    AND     l.request_mode = N'S'
    AND    l.request_status = N'GRANT'
    AND    l.request_owner_type = N'SHARED_TRANSACTION_WORKSPACE') AS db ON s.session_id = db.request_session_id
    CROSS APPLY sys.dm_exec_query_plan(r.plan_handle) pl
    CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
    WHERE r.command LIKE 'DBCC%'
	AND CAST(t.text AS NVARCHAR(4000)) NOT LIKE '%dm_db_index_physical_stats%';


    /* Maintenance Tasks Running - Restore Running - CheckID 3 */
    IF @Seconds > 0
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt, QueryPlan, StartTime, LoginName, NTUserName, ProgramName, HostName, DatabaseID, DatabaseName, OpenTransactionCount)
    SELECT 3 AS CheckID,
        1 AS Priority,
        'Maintenance Tasks Running' AS FindingGroup,
        'Restore Running' AS Finding,
        'http://www.BrentOzar.com/askbrent/backups/' AS URL,
        'Restore of ' + DB_NAME(db.resource_database_id) + ' database (' + (SELECT CAST(CAST(SUM(size * 8.0 / 1024 / 1024) AS BIGINT) AS NVARCHAR) FROM #MasterFiles WHERE database_id = db.resource_database_id) + 'GB) is ' + CAST(r.percent_complete AS NVARCHAR(100)) + '% complete, has been running since ' + CAST(r.start_time AS NVARCHAR(100)) + '. ' AS Details,
        'KILL ' + CAST(r.session_id AS NVARCHAR(100)) + ';' AS HowToStopIt,
        pl.query_plan AS QueryPlan,
        r.start_time AS StartTime,
        s.login_name AS LoginName,
        s.nt_user_name AS NTUserName,
        s.[program_name] AS ProgramName,
        s.[host_name] AS HostName,
        db.[resource_database_id] AS DatabaseID,
        DB_NAME(db.resource_database_id) AS DatabaseName,
        0 AS OpenTransactionCount
    FROM sys.dm_exec_requests r
    INNER JOIN sys.dm_exec_connections c ON r.session_id = c.session_id
    INNER JOIN sys.dm_exec_sessions s ON r.session_id = s.session_id
    INNER JOIN (
    SELECT DISTINCT request_session_id, resource_database_id
    FROM    sys.dm_tran_locks
    WHERE resource_type = N'DATABASE'
    AND     request_mode = N'S'
    AND     request_status = N'GRANT') AS db ON s.session_id = db.request_session_id
    CROSS APPLY sys.dm_exec_query_plan(r.plan_handle) pl
    WHERE r.command LIKE 'RESTORE%';


    /* SQL Server Internal Maintenance - Database File Growing - CheckID 4 */
    IF @Seconds > 0
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt, QueryPlan, StartTime, LoginName, NTUserName, ProgramName, HostName, DatabaseID, DatabaseName, OpenTransactionCount)
    SELECT 4 AS CheckID,
        1 AS Priority,
        'SQL Server Internal Maintenance' AS FindingGroup,
        'Database File Growing' AS Finding,
        'http://www.BrentOzar.com/go/instant' AS URL,
        'SQL Server is waiting for Windows to provide storage space for a database restore, a data file growth, or a log file growth. This task has been running since ' + CAST(r.start_time AS NVARCHAR(100)) + '.' + @LineFeed + 'Check the query plan (expert mode) to identify the database involved.' AS Details,
        'Unfortunately, you can''t stop this, but you can prevent it next time. Check out http://www.BrentOzar.com/go/instant for details.' AS HowToStopIt,
        pl.query_plan AS QueryPlan,
        r.start_time AS StartTime,
        s.login_name AS LoginName,
        s.nt_user_name AS NTUserName,
        s.[program_name] AS ProgramName,
        s.[host_name] AS HostName,
        NULL AS DatabaseID,
        NULL AS DatabaseName,
        0 AS OpenTransactionCount
    FROM sys.dm_os_waiting_tasks t
    INNER JOIN sys.dm_exec_connections c ON t.session_id = c.session_id
    INNER JOIN sys.dm_exec_requests r ON t.session_id = r.session_id
    INNER JOIN sys.dm_exec_sessions s ON r.session_id = s.session_id
    CROSS APPLY sys.dm_exec_query_plan(r.plan_handle) pl
    WHERE t.wait_type = 'PREEMPTIVE_OS_WRITEFILEGATHER'


    /* Query Problems - Long-Running Query Blocking Others - CheckID 5 */
    IF @@VERSION NOT LIKE '%Azure%' AND @Seconds > 0 AND EXISTS(SELECT * FROM sys.dm_os_waiting_tasks WHERE wait_type LIKE 'LCK%' AND wait_duration_ms > 30000)
    BEGIN
        SET @StringToExecute = N'INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt, QueryPlan, QueryText, StartTime, LoginName, NTUserName, ProgramName, HostName, DatabaseID, DatabaseName, OpenTransactionCount)
            SELECT 5 AS CheckID,
                1 AS Priority,
                ''Query Problems'' AS FindingGroup,
                ''Long-Running Query Blocking Others'' AS Finding,
                ''http://www.BrentOzar.com/go/blocking'' AS URL,
                ''Query in '' + COALESCE(DB_NAME(COALESCE((SELECT TOP 1 dbid FROM sys.dm_exec_sql_text(r.sql_handle)),
                    (SELECT TOP 1 t.dbid FROM master..sysprocesses spBlocker CROSS APPLY sys.dm_exec_sql_text(spBlocker.sql_handle) t WHERE spBlocker.spid = tBlocked.blocking_session_id))), ''(Unknown)'') + '' has a last request start time of '' + CAST(s.last_request_start_time AS NVARCHAR(100)) + ''. Query follows:'' ' 
					+ @LineFeed + @LineFeed + 
					'+ CAST(COALESCE((SELECT TOP 1 [text] FROM sys.dm_exec_sql_text(r.sql_handle)),
                    (SELECT TOP 1 [text] FROM master..sysprocesses spBlocker CROSS APPLY sys.dm_exec_sql_text(spBlocker.sql_handle) WHERE spBlocker.spid = tBlocked.blocking_session_id), '''') AS NVARCHAR(2000)) AS Details,
                ''KILL '' + CAST(tBlocked.blocking_session_id AS NVARCHAR(100)) + '';'' AS HowToStopIt,
                (SELECT TOP 1 query_plan FROM sys.dm_exec_query_plan(r.plan_handle)) AS QueryPlan,
                COALESCE((SELECT TOP 1 [text] FROM sys.dm_exec_sql_text(r.sql_handle)),
                    (SELECT TOP 1 [text] FROM master..sysprocesses spBlocker CROSS APPLY sys.dm_exec_sql_text(spBlocker.sql_handle) WHERE spBlocker.spid = tBlocked.blocking_session_id)) AS QueryText,
                r.start_time AS StartTime,
                s.login_name AS LoginName,
                s.nt_user_name AS NTUserName,
                s.[program_name] AS ProgramName,
                s.[host_name] AS HostName,
                r.[database_id] AS DatabaseID,
                DB_NAME(r.database_id) AS DatabaseName,
                0 AS OpenTransactionCount
            FROM sys.dm_os_waiting_tasks tBlocked
	        INNER JOIN sys.dm_exec_sessions s ON tBlocked.blocking_session_id = s.session_id
            LEFT OUTER JOIN sys.dm_exec_requests r ON s.session_id = r.session_id
            INNER JOIN sys.dm_exec_connections c ON s.session_id = c.session_id
            WHERE tBlocked.wait_type LIKE ''LCK%'' AND tBlocked.wait_duration_ms > 30000;'
		EXECUTE sp_executesql @StringToExecute;
    END

    /* Query Problems - Plan Cache Erased Recently */
    IF DATEADD(mi, -15, SYSDATETIMEOFFSET()) < (SELECT TOP 1 creation_time FROM sys.dm_exec_query_stats ORDER BY creation_time)
    BEGIN
        INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt)
        SELECT TOP 1 7 AS CheckID,
            50 AS Priority,
            'Query Problems' AS FindingGroup,
            'Plan Cache Erased Recently' AS Finding,
            'http://www.BrentOzar.com/askbrent/plan-cache-erased-recently/' AS URL,
            'The oldest query in the plan cache was created at ' + CAST(creation_time AS NVARCHAR(50)) + '. ' + @LineFeed + @LineFeed
                + 'This indicates that someone ran DBCC FREEPROCCACHE at that time,' + @LineFeed
                + 'Giving SQL Server temporary amnesia. Now, as queries come in,' + @LineFeed
                + 'SQL Server has to use a lot of CPU power in order to build execution' + @LineFeed
                + 'plans and put them in cache again. This causes high CPU loads.' AS Details,
            'Find who did that, and stop them from doing it again.' AS HowToStopIt
        FROM sys.dm_exec_query_stats
        ORDER BY creation_time
    END;


    /* Query Problems - Sleeping Query with Open Transactions - CheckID 8 */
    IF @Seconds > 0
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt, StartTime, LoginName, NTUserName, ProgramName, HostName, DatabaseID, DatabaseName, QueryText, OpenTransactionCount)
    SELECT 8 AS CheckID,
        50 AS Priority,
        'Query Problems' AS FindingGroup,
        'Sleeping Query with Open Transactions' AS Finding,
        'http://www.brentozar.com/askbrent/sleeping-query-with-open-transactions/' AS URL,
        'Database: ' + DB_NAME(db.resource_database_id) + @LineFeed + 'Host: ' + s.[host_name] + @LineFeed + 'Program: ' + s.[program_name] + @LineFeed + 'Asleep with open transactions and locks since ' + CAST(s.last_request_end_time AS NVARCHAR(100)) + '. ' AS Details,
        'KILL ' + CAST(s.session_id AS NVARCHAR(100)) + ';' AS HowToStopIt,
        s.last_request_start_time AS StartTime,
        s.login_name AS LoginName,
        s.nt_user_name AS NTUserName,
        s.[program_name] AS ProgramName,
        s.[host_name] AS HostName,
        db.[resource_database_id] AS DatabaseID,
        DB_NAME(db.resource_database_id) AS DatabaseName,
        (SELECT TOP 1 [text] FROM sys.dm_exec_sql_text(c.most_recent_sql_handle)) AS QueryText,
        sessions_with_transactions.open_transaction_count AS OpenTransactionCount
    FROM (SELECT session_id, SUM(open_transaction_count) AS open_transaction_count FROM sys.dm_exec_requests WHERE open_transaction_count > 0 GROUP BY session_id) AS sessions_with_transactions
    INNER JOIN sys.dm_exec_sessions s ON sessions_with_transactions.session_id = s.session_id
    INNER JOIN sys.dm_exec_connections c ON s.session_id = c.session_id
    INNER JOIN (
    SELECT DISTINCT request_session_id, resource_database_id
    FROM    sys.dm_tran_locks
    WHERE resource_type = N'DATABASE'
    AND     request_mode = N'S'
    AND     request_status = N'GRANT'
    AND     request_owner_type = N'SHARED_TRANSACTION_WORKSPACE') AS db ON s.session_id = db.request_session_id
    WHERE s.status = 'sleeping'
    AND s.last_request_end_time < DATEADD(ss, -10, SYSDATETIMEOFFSET())
    AND EXISTS(SELECT * FROM sys.dm_tran_locks WHERE request_session_id = s.session_id
    AND NOT (resource_type = N'DATABASE' AND request_mode = N'S' AND request_status = N'GRANT' AND request_owner_type = N'SHARED_TRANSACTION_WORKSPACE'))


    /* Query Problems - Query Rolling Back - CheckID 9 */
    IF @Seconds > 0
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt, StartTime, LoginName, NTUserName, ProgramName, HostName, DatabaseID, DatabaseName, QueryText)
    SELECT 9 AS CheckID,
        1 AS Priority,
        'Query Problems' AS FindingGroup,
        'Query Rolling Back' AS Finding,
        'http://www.BrentOzar.com/askbrent/rollback/' AS URL,
        'Rollback started at ' + CAST(r.start_time AS NVARCHAR(100)) + ', is ' + CAST(r.percent_complete AS NVARCHAR(100)) + '% complete.' AS Details,
        'Unfortunately, you can''t stop this. Whatever you do, don''t restart the server in an attempt to fix it - SQL Server will keep rolling back.' AS HowToStopIt,
        r.start_time AS StartTime,
        s.login_name AS LoginName,
        s.nt_user_name AS NTUserName,
        s.[program_name] AS ProgramName,
        s.[host_name] AS HostName,
        db.[resource_database_id] AS DatabaseID,
        DB_NAME(db.resource_database_id) AS DatabaseName,
        (SELECT TOP 1 [text] FROM sys.dm_exec_sql_text(c.most_recent_sql_handle)) AS QueryText
    FROM sys.dm_exec_sessions s
    INNER JOIN sys.dm_exec_connections c ON s.session_id = c.session_id
    INNER JOIN sys.dm_exec_requests r ON s.session_id = r.session_id
    LEFT OUTER JOIN (
        SELECT DISTINCT request_session_id, resource_database_id
        FROM    sys.dm_tran_locks
        WHERE resource_type = N'DATABASE'
        AND     request_mode = N'S'
        AND     request_status = N'GRANT'
        AND     request_owner_type = N'SHARED_TRANSACTION_WORKSPACE') AS db ON s.session_id = db.request_session_id
    WHERE r.status = 'rollback'


    /* Server Performance - Page Life Expectancy Low - CheckID 10 */
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt)
    SELECT 10 AS CheckID,
        50 AS Priority,
        'Server Performance' AS FindingGroup,
        'Page Life Expectancy Low' AS Finding,
        'http://www.BrentOzar.com/askbrent/page-life-expectancy/' AS URL,
        'SQL Server Buffer Manager:Page life expectancy is ' + CAST(c.cntr_value AS NVARCHAR(10)) + ' seconds.' + @LineFeed
            + 'This means SQL Server can only keep data pages in memory for that many seconds after reading those pages in from storage.' + @LineFeed
            + 'This is a symptom, not a cause - it indicates very read-intensive queries that need an index, or insufficient server memory.' AS Details,
        'Add more memory to the server, or find the queries reading a lot of data, and make them more efficient (or fix them with indexes).' AS HowToStopIt
    FROM sys.dm_os_performance_counters c
    WHERE object_name LIKE 'SQLServer:Buffer Manager%'
    AND counter_name LIKE 'Page life expectancy%'
    AND cntr_value < 300

    /* Server Performance - Too Much Free Memory - CheckID 34 */
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt)
    SELECT 34 AS CheckID,
        50 AS Priority,
        'Server Performance' AS FindingGroup,
        'Too Much Free Memory' AS Finding,
        'https://BrentOzar.com/go/freememory' AS URL,
		CAST((CAST(cFree.cntr_value AS BIGINT) / 1024 / 1024 ) AS NVARCHAR(100)) + N'GB of free memory inside SQL Server''s buffer pool,' + @LineFeed + ' which is ' + CAST((CAST(cTotal.cntr_value AS BIGINT) / 1024 / 1024) AS NVARCHAR(100)) + N'GB. You would think lots of free memory would be good, but check out the URL for more information.' AS Details,
        'Run sp_BlitzCache @SortOrder = ''memory grant'' to find queries with huge memory grants and tune them.' AS HowToStopIt
		FROM sys.dm_os_performance_counters cFree
		INNER JOIN sys.dm_os_performance_counters cTotal ON cTotal.object_name LIKE N'%Memory Manager%'
			AND cTotal.counter_name = N'Total Server Memory (KB)                                                                                                        '
		WHERE cFree.object_name LIKE N'%Memory Manager%'
			AND cFree.counter_name = N'Free Memory (KB)                                                                                                                '
			AND CAST(cTotal.cntr_value AS BIGINT) > 20480000000
			AND CAST(cTotal.cntr_value AS BIGINT) * .3 <= CAST(cFree.cntr_value AS BIGINT)
            AND CAST(SERVERPROPERTY('edition') AS VARCHAR(100)) NOT LIKE '%Standard%';

    /* Server Performance - Target Memory Lower Than Max - CheckID 35 */
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt)
    SELECT 35 AS CheckID,
        10 AS Priority,
        'Server Performance' AS FindingGroup,
        'Target Memory Lower Than Max' AS Finding,
        'https://BrentOzar.com/go/target' AS URL,
		N'Max server memory is ' + CAST(cMax.value_in_use AS NVARCHAR(50)) + N' MB but target server memory is only ' + CAST((CAST(cTarget.cntr_value AS BIGINT) / 1024) AS NVARCHAR(50)) + N' MB,' + @LineFeed
            + N'indicating that SQL Server may be under external memory pressure or max server memory may be set too high.' AS Details,
        'Investigate what OS processes are using memory, and double-check the max server memory setting.' AS HowToStopIt
        FROM sys.configurations cMax
        INNER JOIN sys.dm_os_performance_counters cTarget ON cTarget.object_name LIKE N'%Memory Manager%'
	        AND cTarget.counter_name = N'Target Server Memory (KB)                                                                                                       '
        WHERE cMax.name = 'max server memory (MB)'
            AND CAST(cMax.value_in_use AS BIGINT) >= 1.5 * (CAST(cTarget.cntr_value AS BIGINT) / 1024)
            AND CAST(cMax.value_in_use AS BIGINT) < 2147483647; /* Not set to default of unlimited */

    /* Server Info - Database Size, Total GB - CheckID 21 */
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, Details, DetailsInt, URL)
    SELECT 21 AS CheckID,
        251 AS Priority,
        'Server Info' AS FindingGroup,
        'Database Size, Total GB' AS Finding,
        CAST(SUM (CAST(size AS BIGINT)*8./1024./1024.) AS VARCHAR(100)) AS Details,
        SUM (CAST(size AS BIGINT))*8./1024./1024. AS DetailsInt,
        'http://www.BrentOzar.com/askbrent/' AS URL
    FROM #MasterFiles
    WHERE database_id > 4

    /* Server Info - Database Count - CheckID 22 */
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, Details, DetailsInt, URL)
    SELECT 22 AS CheckID,
        251 AS Priority,
        'Server Info' AS FindingGroup,
        'Database Count' AS Finding,
        CAST(SUM(1) AS VARCHAR(100)) AS Details,
        SUM (1) AS DetailsInt,
        'http://www.BrentOzar.com/askbrent/' AS URL
    FROM sys.databases
    WHERE database_id > 4

    /* Server Performance - High CPU Utilization CheckID 24 */
    IF @Seconds < 30
        BEGIN
        /* If we're waiting less than 30 seconds, run this check now rather than wait til the end.
           We get this data from the ring buffers, and it's only updated once per minute, so might
           as well get it now - whereas if we're checking 30+ seconds, it might get updated by the
           end of our sp_BlitzFirst session. */
        INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, Details, DetailsInt, URL)
        SELECT 24, 50, 'Server Performance', 'High CPU Utilization', CAST(100 - SystemIdle AS NVARCHAR(20)) + N'%. Ring buffer details: ' + CAST(record AS NVARCHAR(4000)), 100 - SystemIdle, 'http://www.BrentOzar.com/go/cpu'
            FROM (
                SELECT record,
                    record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') AS SystemIdle
                FROM (
                    SELECT TOP 1 CONVERT(XML, record) AS record
                    FROM sys.dm_os_ring_buffers
                    WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
                    AND record LIKE '%<SystemHealth>%'
                    ORDER BY timestamp DESC) AS rb
            ) AS y
            WHERE 100 - SystemIdle >= 50

        INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, Details, DetailsInt, URL)
        SELECT 23, 250, 'Server Info', 'CPU Utilization', CAST(100 - SystemIdle AS NVARCHAR(20)) + N'%. Ring buffer details: ' + CAST(record AS NVARCHAR(4000)), 100 - SystemIdle, 'http://www.BrentOzar.com/go/cpu'
            FROM (
                SELECT record,
                    record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') AS SystemIdle
                FROM (
                    SELECT TOP 1 CONVERT(XML, record) AS record
                    FROM sys.dm_os_ring_buffers
                    WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
                    AND record LIKE '%<SystemHealth>%'
                    ORDER BY timestamp DESC) AS rb
            ) AS y
		
		/* Highlight if non SQL processes are using >25% CPU */
		INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, Details, DetailsInt, URL)
	    SELECT 28,	50,	'Server Performance', 'High CPU Utilization - Not SQL', CONVERT(NVARCHAR(100),100 - (y.SQLUsage + y.SystemIdle)) + N'% - Other Processes (not SQL Server) are using this much CPU. This may impact on the performance of your SQL Server instance', 100 - (y.SQLUsage + y.SystemIdle), 'http://www.BrentOzar.com/go/cpu'
            FROM (
                SELECT record,
                    record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') AS SystemIdle
					,record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int') AS SQLUsage
                FROM (
                    SELECT TOP 1 CONVERT(XML, record) AS record
                    FROM sys.dm_os_ring_buffers
                    WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
                    AND record LIKE '%<SystemHealth>%'
                    ORDER BY timestamp DESC) AS rb
            ) AS y
            WHERE 100 - (y.SQLUsage + y.SystemIdle) >= 25
		
        END /* IF @Seconds < 30 */

	RAISERROR('Finished running investigatory queries',10,1) WITH NOWAIT;


    /* End of checks. If we haven't waited @Seconds seconds, wait. */
    IF SYSDATETIMEOFFSET() < @FinishSampleTime
		BEGIN
		RAISERROR('Waiting to match @Seconds parameter',10,1) WITH NOWAIT;
        WAITFOR TIME @FinishSampleTimeWaitFor;
		END

	RAISERROR('Capturing second pass of wait stats, perfmon counters, file stats',10,1) WITH NOWAIT;
    /* Populate #FileStats, #PerfmonStats, #WaitStats with DMV data. In a second, we'll compare these. */
    INSERT #WaitStats(Pass, SampleTime, wait_type, wait_time_ms, signal_wait_time_ms, waiting_tasks_count)
		SELECT 
		x.Pass, 
		x.SampleTime, 
		x.wait_type, 
		SUM(x.sum_wait_time_ms) AS sum_wait_time_ms, 
		SUM(x.sum_signal_wait_time_ms) AS sum_signal_wait_time_ms, 
		SUM(x.sum_waiting_tasks) AS sum_waiting_tasks
		FROM (
		SELECT  
				2 AS Pass,
				SYSDATETIMEOFFSET() AS SampleTime,
				owt.wait_type,
		        SUM(owt.wait_duration_ms) OVER (PARTITION BY owt.wait_type, owt.session_id)
					 - CASE WHEN @Seconds = 0 THEN 0 ELSE (@Seconds * 1000) END AS sum_wait_time_ms,
				0 AS sum_signal_wait_time_ms,
				CASE @Seconds WHEN 0 THEN 0 ELSE 1 END AS sum_waiting_tasks
			FROM    sys.dm_os_waiting_tasks owt
			WHERE owt.session_id > 50
			AND owt.wait_duration_ms >= CASE @Seconds WHEN 0 THEN 0 ELSE @Seconds * 1000 END
		UNION ALL
		SELECT
		       2 AS Pass,
		       SYSDATETIMEOFFSET() AS SampleTime,
		       os.wait_type,
			   SUM(os.wait_time_ms) OVER (PARTITION BY os.wait_type) AS sum_wait_time_ms,
			   SUM(os.signal_wait_time_ms) OVER (PARTITION BY os.wait_type ) AS sum_signal_wait_time_ms,
			   SUM(os.waiting_tasks_count) OVER (PARTITION BY os.wait_type) AS sum_waiting_tasks
		   FROM sys.dm_os_wait_stats os
		) x
		   WHERE x.wait_type NOT IN (
                  'BROKER_EVENTHANDLER'
                , 'BROKER_RECEIVE_WAITFOR'
                , 'BROKER_TASK_STOP'
                , 'BROKER_TO_FLUSH'
                , 'BROKER_TRANSMITTER'
                , 'CHECKPOINT_QUEUE'
                , 'DBMIRROR_DBM_EVENT'
                , 'DBMIRROR_DBM_MUTEX'
                , 'DBMIRROR_EVENTS_QUEUE'
                , 'DBMIRROR_WORKER_QUEUE'
                , 'DBMIRRORING_CMD'
                , 'DIRTY_PAGE_POLL'
                , 'DISPATCHER_QUEUE_SEMAPHORE'
                , 'FT_IFTS_SCHEDULER_IDLE_WAIT'
                , 'FT_IFTSHC_MUTEX'
                , 'HADR_CLUSAPI_CALL'
                , 'HADR_FILESTREAM_IOMGR_IOCOMPLETION'
                , 'HADR_LOGCAPTURE_WAIT'
                , 'HADR_NOTIFICATION_DEQUEUE'
                , 'HADR_TIMER_TASK'
                , 'HADR_WORK_QUEUE'
                , 'LAZYWRITER_SLEEP'
                , 'LOGMGR_QUEUE'
                , 'ONDEMAND_TASK_QUEUE'
                , 'PREEMPTIVE_HADR_LEASE_MECHANISM'
                , 'PREEMPTIVE_SP_SERVER_DIAGNOSTICS'
                , 'QDS_ASYNC_QUEUE'
                , 'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP'
                , 'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP'
                , 'QDS_SHUTDOWN_QUEUE'
                , 'REDO_THREAD_PENDING_WORK'
                , 'REQUEST_FOR_DEADLOCK_SEARCH'
                , 'SLEEP_SYSTEMTASK'
                , 'SLEEP_TASK'
                , 'SP_SERVER_DIAGNOSTICS_SLEEP'
                , 'SQLTRACE_BUFFER_FLUSH'
                , 'SQLTRACE_INCREMENTAL_FLUSH_SLEEP'
                , 'UCS_SESSION_REGISTRATION'
                , 'WAIT_XTP_OFFLINE_CKPT_NEW_LOG'
                , 'WAITFOR'
                , 'XE_DISPATCHER_WAIT'
                , 'XE_LIVE_TARGET_TVF'
                , 'XE_TIMER_EVENT'
		   )
		GROUP BY x.Pass, x.SampleTime, x.wait_type
		ORDER BY sum_wait_time_ms DESC;

    INSERT INTO #FileStats (Pass, SampleTime, DatabaseID, FileID, DatabaseName, FileLogicalName, SizeOnDiskMB, io_stall_read_ms ,
        num_of_reads, [bytes_read] , io_stall_write_ms,num_of_writes, [bytes_written], PhysicalName, TypeDesc, avg_stall_read_ms, avg_stall_write_ms)
    SELECT         2 AS Pass,
        SYSDATETIMEOFFSET() AS SampleTime,
        mf.[database_id],
        mf.[file_id],
        DB_NAME(vfs.database_id) AS [db_name],
        mf.name + N' [' + mf.type_desc COLLATE SQL_Latin1_General_CP1_CI_AS + N']' AS file_logical_name ,
        CAST(( ( vfs.size_on_disk_bytes / 1024.0 ) / 1024.0 ) AS INT) AS size_on_disk_mb ,
        vfs.io_stall_read_ms ,
        vfs.num_of_reads ,
        vfs.[num_of_bytes_read],
        vfs.io_stall_write_ms ,
        vfs.num_of_writes ,
        vfs.[num_of_bytes_written],
        mf.physical_name,
        mf.type_desc,
        0,
        0
    FROM sys.dm_io_virtual_file_stats (NULL, NULL) AS vfs
    INNER JOIN #MasterFiles AS mf ON vfs.file_id = mf.file_id
        AND vfs.database_id = mf.database_id
    WHERE vfs.num_of_reads > 0
        OR vfs.num_of_writes > 0;

    INSERT INTO #PerfmonStats (Pass, SampleTime, [object_name],[counter_name],[instance_name],[cntr_value],[cntr_type])
    SELECT         2 AS Pass,
        SYSDATETIMEOFFSET() AS SampleTime,
        RTRIM(dmv.object_name), RTRIM(dmv.counter_name), RTRIM(dmv.instance_name), dmv.cntr_value, dmv.cntr_type
        FROM #PerfmonCounters counters
        INNER JOIN sys.dm_os_performance_counters dmv ON counters.counter_name COLLATE SQL_Latin1_General_CP1_CI_AS = RTRIM(dmv.counter_name) COLLATE SQL_Latin1_General_CP1_CI_AS
            AND counters.[object_name] COLLATE SQL_Latin1_General_CP1_CI_AS = RTRIM(dmv.[object_name]) COLLATE SQL_Latin1_General_CP1_CI_AS
            AND (counters.[instance_name] IS NULL OR counters.[instance_name] COLLATE SQL_Latin1_General_CP1_CI_AS = RTRIM(dmv.[instance_name]) COLLATE SQL_Latin1_General_CP1_CI_AS)

    /* Set the latencies and averages. We could do this with a CTE, but we're not ambitious today. */
    UPDATE fNow
    SET avg_stall_read_ms = ((fNow.io_stall_read_ms - fBase.io_stall_read_ms) / (fNow.num_of_reads - fBase.num_of_reads))
    FROM #FileStats fNow
    INNER JOIN #FileStats fBase ON fNow.DatabaseID = fBase.DatabaseID AND fNow.FileID = fBase.FileID AND fNow.SampleTime > fBase.SampleTime AND fNow.num_of_reads > fBase.num_of_reads AND fNow.io_stall_read_ms > fBase.io_stall_read_ms
    WHERE (fNow.num_of_reads - fBase.num_of_reads) > 0

    UPDATE fNow
    SET avg_stall_write_ms = ((fNow.io_stall_write_ms - fBase.io_stall_write_ms) / (fNow.num_of_writes - fBase.num_of_writes))
    FROM #FileStats fNow
    INNER JOIN #FileStats fBase ON fNow.DatabaseID = fBase.DatabaseID AND fNow.FileID = fBase.FileID AND fNow.SampleTime > fBase.SampleTime AND fNow.num_of_writes > fBase.num_of_writes AND fNow.io_stall_write_ms > fBase.io_stall_write_ms
    WHERE (fNow.num_of_writes - fBase.num_of_writes) > 0

    UPDATE pNow
        SET [value_delta] = pNow.cntr_value - pFirst.cntr_value,
            [value_per_second] = ((1.0 * pNow.cntr_value - pFirst.cntr_value) / DATEDIFF(ss, pFirst.SampleTime, pNow.SampleTime))
        FROM #PerfmonStats pNow
            INNER JOIN #PerfmonStats pFirst ON pFirst.[object_name] = pNow.[object_name] AND pFirst.counter_name = pNow.counter_name AND (pFirst.instance_name = pNow.instance_name OR (pFirst.instance_name IS NULL AND pNow.instance_name IS NULL))
                AND pNow.ID > pFirst.ID
        WHERE  DATEDIFF(ss, pFirst.SampleTime, pNow.SampleTime) > 0;


    /* If we're within 10 seconds of our projected finish time, do the plan cache analysis. */
    IF DATEDIFF(ss, @FinishSampleTime, SYSDATETIMEOFFSET()) > 10 AND @CheckProcedureCache = 1
        BEGIN

            INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details)
            VALUES (18, 210, 'Query Stats', 'Plan Cache Analysis Skipped', 'http://www.BrentOzar.com/go/topqueries',
                'Due to excessive load, the plan cache analysis was skipped. To override this, use @ExpertMode = 1.')

        END
    ELSE IF @CheckProcedureCache = 1
        BEGIN


		RAISERROR('@CheckProcedureCache = 1, capturing second pass of plan cache',10,1) WITH NOWAIT;

        /* Populate #QueryStats. SQL 2005 doesn't have query hash or query plan hash. */
		IF @@VERSION LIKE 'Microsoft SQL Server 2005%'
			BEGIN
			IF @FilterPlansByDatabase IS NULL
				BEGIN
				SET @StringToExecute = N'INSERT INTO #QueryStats ([sql_handle], Pass, SampleTime, statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, query_hash, query_plan_hash, Points)
											SELECT [sql_handle], 2 AS Pass, SYSDATETIMEOFFSET(), statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, NULL AS query_hash, NULL AS query_plan_hash, 0
											FROM sys.dm_exec_query_stats qs
											WHERE qs.last_execution_time >= @StartSampleTimeText;';
				END
			ELSE
				BEGIN
				SET @StringToExecute = N'INSERT INTO #QueryStats ([sql_handle], Pass, SampleTime, statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, query_hash, query_plan_hash, Points)
											SELECT [sql_handle], 2 AS Pass, SYSDATETIMEOFFSET(), statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, NULL AS query_hash, NULL AS query_plan_hash, 0
											FROM sys.dm_exec_query_stats qs
												CROSS APPLY sys.dm_exec_plan_attributes(qs.plan_handle) AS attr
												INNER JOIN #FilterPlansByDatabase dbs ON CAST(attr.value AS INT) = dbs.DatabaseID
											WHERE qs.last_execution_time >= @StartSampleTimeText
												AND attr.attribute = ''dbid'';';
				END
			END
		ELSE
			BEGIN
			IF @FilterPlansByDatabase IS NULL
				BEGIN
				SET @StringToExecute = N'INSERT INTO #QueryStats ([sql_handle], Pass, SampleTime, statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, query_hash, query_plan_hash, Points)
											SELECT [sql_handle], 2 AS Pass, SYSDATETIMEOFFSET(), statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, query_hash, query_plan_hash, 0
											FROM sys.dm_exec_query_stats qs
											WHERE qs.last_execution_time >= @StartSampleTimeText';
				END
			ELSE
				BEGIN
				SET @StringToExecute = N'INSERT INTO #QueryStats ([sql_handle], Pass, SampleTime, statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, query_hash, query_plan_hash, Points)
											SELECT [sql_handle], 2 AS Pass, SYSDATETIMEOFFSET(), statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, query_hash, query_plan_hash, 0
											FROM sys.dm_exec_query_stats qs
											CROSS APPLY sys.dm_exec_plan_attributes(qs.plan_handle) AS attr
											INNER JOIN #FilterPlansByDatabase dbs ON CAST(attr.value AS INT) = dbs.DatabaseID
											WHERE qs.last_execution_time >= @StartSampleTimeText
												AND attr.attribute = ''dbid'';';
				END
			END
		/* Old version pre-2016/06/13:
        IF @@VERSION LIKE 'Microsoft SQL Server 2005%'
            SET @StringToExecute = N'INSERT INTO #QueryStats ([sql_handle], Pass, SampleTime, statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, query_hash, query_plan_hash, Points)
                                        SELECT [sql_handle], 2 AS Pass, SYSDATETIMEOFFSET(), statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, NULL AS query_hash, NULL AS query_plan_hash, 0
                                        FROM sys.dm_exec_query_stats qs
                                        WHERE qs.last_execution_time >= @StartSampleTimeText;';
        ELSE
            SET @StringToExecute = N'INSERT INTO #QueryStats ([sql_handle], Pass, SampleTime, statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, query_hash, query_plan_hash, Points)
                                        SELECT [sql_handle], 2 AS Pass, SYSDATETIMEOFFSET(), statement_start_offset, statement_end_offset, plan_generation_num, plan_handle, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time, query_hash, query_plan_hash, 0
                                        FROM sys.dm_exec_query_stats qs
                                        WHERE qs.last_execution_time >= @StartSampleTimeText;';
		*/
        SET @ParmDefinitions = N'@StartSampleTimeText NVARCHAR(100)';
        SET @Parm1 = CONVERT(NVARCHAR(100), CAST(@StartSampleTime AS DATETIME), 127);

        EXECUTE sp_executesql @StringToExecute, @ParmDefinitions, @StartSampleTimeText = @Parm1;

		RAISERROR('@CheckProcedureCache = 1, totaling up plan cache metrics',10,1) WITH NOWAIT;

        /* Get the totals for the entire plan cache */
        INSERT INTO #QueryStats (Pass, SampleTime, execution_count, total_worker_time, total_physical_reads, total_logical_writes, total_logical_reads, total_clr_time, total_elapsed_time, creation_time)
        SELECT 0 AS Pass, SYSDATETIMEOFFSET(), SUM(execution_count), SUM(total_worker_time), SUM(total_physical_reads), SUM(total_logical_writes), SUM(total_logical_reads), SUM(total_clr_time), SUM(total_elapsed_time), MIN(creation_time)
            FROM sys.dm_exec_query_stats qs;


		RAISERROR('@CheckProcedureCache = 1, so analyzing execution plans',10,1) WITH NOWAIT;
        /*
        Pick the most resource-intensive queries to review. Update the Points field
        in #QueryStats - if a query is in the top 10 for logical reads, CPU time,
        duration, or execution, add 1 to its points.
        */
        WITH qsTop AS (
        SELECT TOP 10 qsNow.ID
        FROM #QueryStats qsNow
          INNER JOIN #QueryStats qsFirst ON qsNow.[sql_handle] = qsFirst.[sql_handle] AND qsNow.statement_start_offset = qsFirst.statement_start_offset AND qsNow.statement_end_offset = qsFirst.statement_end_offset AND qsNow.plan_generation_num = qsFirst.plan_generation_num AND qsNow.plan_handle = qsFirst.plan_handle AND qsFirst.Pass = 1
        WHERE qsNow.total_elapsed_time > qsFirst.total_elapsed_time
            AND qsNow.Pass = 2
            AND qsNow.total_elapsed_time - qsFirst.total_elapsed_time > 1000000 /* Only queries with over 1 second of runtime */
        ORDER BY (qsNow.total_elapsed_time - COALESCE(qsFirst.total_elapsed_time, 0)) DESC)
        UPDATE #QueryStats
            SET Points = Points + 1
            FROM #QueryStats qs
            INNER JOIN qsTop ON qs.ID = qsTop.ID;

        WITH qsTop AS (
        SELECT TOP 10 qsNow.ID
        FROM #QueryStats qsNow
          INNER JOIN #QueryStats qsFirst ON qsNow.[sql_handle] = qsFirst.[sql_handle] AND qsNow.statement_start_offset = qsFirst.statement_start_offset AND qsNow.statement_end_offset = qsFirst.statement_end_offset AND qsNow.plan_generation_num = qsFirst.plan_generation_num AND qsNow.plan_handle = qsFirst.plan_handle AND qsFirst.Pass = 1
        WHERE qsNow.total_logical_reads > qsFirst.total_logical_reads
            AND qsNow.Pass = 2
            AND qsNow.total_logical_reads - qsFirst.total_logical_reads > 1000 /* Only queries with over 1000 reads */
        ORDER BY (qsNow.total_logical_reads - COALESCE(qsFirst.total_logical_reads, 0)) DESC)
        UPDATE #QueryStats
            SET Points = Points + 1
            FROM #QueryStats qs
            INNER JOIN qsTop ON qs.ID = qsTop.ID;

        WITH qsTop AS (
        SELECT TOP 10 qsNow.ID
        FROM #QueryStats qsNow
          INNER JOIN #QueryStats qsFirst ON qsNow.[sql_handle] = qsFirst.[sql_handle] AND qsNow.statement_start_offset = qsFirst.statement_start_offset AND qsNow.statement_end_offset = qsFirst.statement_end_offset AND qsNow.plan_generation_num = qsFirst.plan_generation_num AND qsNow.plan_handle = qsFirst.plan_handle AND qsFirst.Pass = 1
        WHERE qsNow.total_worker_time > qsFirst.total_worker_time
            AND qsNow.Pass = 2
            AND qsNow.total_worker_time - qsFirst.total_worker_time > 1000000 /* Only queries with over 1 second of worker time */
        ORDER BY (qsNow.total_worker_time - COALESCE(qsFirst.total_worker_time, 0)) DESC)
        UPDATE #QueryStats
            SET Points = Points + 1
            FROM #QueryStats qs
            INNER JOIN qsTop ON qs.ID = qsTop.ID;

        WITH qsTop AS (
        SELECT TOP 10 qsNow.ID
        FROM #QueryStats qsNow
          INNER JOIN #QueryStats qsFirst ON qsNow.[sql_handle] = qsFirst.[sql_handle] AND qsNow.statement_start_offset = qsFirst.statement_start_offset AND qsNow.statement_end_offset = qsFirst.statement_end_offset AND qsNow.plan_generation_num = qsFirst.plan_generation_num AND qsNow.plan_handle = qsFirst.plan_handle AND qsFirst.Pass = 1
        WHERE qsNow.execution_count > qsFirst.execution_count
            AND qsNow.Pass = 2
            AND (qsNow.total_elapsed_time - qsFirst.total_elapsed_time > 1000000 /* Only queries with over 1 second of runtime */
                OR qsNow.total_logical_reads - qsFirst.total_logical_reads > 1000 /* Only queries with over 1000 reads */
                OR qsNow.total_worker_time - qsFirst.total_worker_time > 1000000 /* Only queries with over 1 second of worker time */)
        ORDER BY (qsNow.execution_count - COALESCE(qsFirst.execution_count, 0)) DESC)
        UPDATE #QueryStats
            SET Points = Points + 1
            FROM #QueryStats qs
            INNER JOIN qsTop ON qs.ID = qsTop.ID;

        /* Query Stats - CheckID 17 - Most Resource-Intensive Queries */
        INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt, QueryPlan, QueryText, QueryStatsNowID, QueryStatsFirstID, PlanHandle)
        SELECT 17, 210, 'Query Stats', 'Most Resource-Intensive Queries', 'http://www.BrentOzar.com/go/topqueries',
            'Query stats during the sample:' + @LineFeed +
            'Executions: ' + CAST(qsNow.execution_count - (COALESCE(qsFirst.execution_count, 0)) AS NVARCHAR(100)) + @LineFeed +
            'Elapsed Time: ' + CAST(qsNow.total_elapsed_time - (COALESCE(qsFirst.total_elapsed_time, 0)) AS NVARCHAR(100)) + @LineFeed +
            'CPU Time: ' + CAST(qsNow.total_worker_time - (COALESCE(qsFirst.total_worker_time, 0)) AS NVARCHAR(100)) + @LineFeed +
            'Logical Reads: ' + CAST(qsNow.total_logical_reads - (COALESCE(qsFirst.total_logical_reads, 0)) AS NVARCHAR(100)) + @LineFeed +
            'Logical Writes: ' + CAST(qsNow.total_logical_writes - (COALESCE(qsFirst.total_logical_writes, 0)) AS NVARCHAR(100)) + @LineFeed +
            'CLR Time: ' + CAST(qsNow.total_clr_time - (COALESCE(qsFirst.total_clr_time, 0)) AS NVARCHAR(100)) + @LineFeed +
            @LineFeed + @LineFeed + 'Query stats since ' + CONVERT(NVARCHAR(100), qsNow.creation_time ,121) + @LineFeed +
            'Executions: ' + CAST(qsNow.execution_count AS NVARCHAR(100)) +
                    CASE qsTotal.execution_count WHEN 0 THEN '' ELSE (' - Percent of Server Total: ' + CAST(CAST(100.0 * qsNow.execution_count / qsTotal.execution_count AS DECIMAL(6,2)) AS NVARCHAR(100)) + '%') END + @LineFeed +
            'Elapsed Time: ' + CAST(qsNow.total_elapsed_time AS NVARCHAR(100)) +
                    CASE qsTotal.total_elapsed_time WHEN 0 THEN '' ELSE (' - Percent of Server Total: ' + CAST(CAST(100.0 * qsNow.total_elapsed_time / qsTotal.total_elapsed_time AS DECIMAL(6,2)) AS NVARCHAR(100)) + '%') END + @LineFeed +
            'CPU Time: ' + CAST(qsNow.total_worker_time AS NVARCHAR(100)) +
                    CASE qsTotal.total_worker_time WHEN 0 THEN '' ELSE (' - Percent of Server Total: ' + CAST(CAST(100.0 * qsNow.total_worker_time / qsTotal.total_worker_time AS DECIMAL(6,2)) AS NVARCHAR(100)) + '%') END + @LineFeed +
            'Logical Reads: ' + CAST(qsNow.total_logical_reads AS NVARCHAR(100)) +
                    CASE qsTotal.total_logical_reads WHEN 0 THEN '' ELSE (' - Percent of Server Total: ' + CAST(CAST(100.0 * qsNow.total_logical_reads / qsTotal.total_logical_reads AS DECIMAL(6,2)) AS NVARCHAR(100)) + '%') END + @LineFeed +
            'Logical Writes: ' + CAST(qsNow.total_logical_writes AS NVARCHAR(100)) +
                    CASE qsTotal.total_logical_writes WHEN 0 THEN '' ELSE (' - Percent of Server Total: ' + CAST(CAST(100.0 * qsNow.total_logical_writes / qsTotal.total_logical_writes AS DECIMAL(6,2)) AS NVARCHAR(100)) + '%') END + @LineFeed +
            'CLR Time: ' + CAST(qsNow.total_clr_time AS NVARCHAR(100)) +
                    CASE qsTotal.total_clr_time WHEN 0 THEN '' ELSE (' - Percent of Server Total: ' + CAST(CAST(100.0 * qsNow.total_clr_time / qsTotal.total_clr_time AS DECIMAL(6,2)) AS NVARCHAR(100)) + '%') END + @LineFeed +
            --@LineFeed + @LineFeed + 'Query hash: ' + CAST(qsNow.query_hash AS NVARCHAR(100)) + @LineFeed +
            --@LineFeed + @LineFeed + 'Query plan hash: ' + CAST(qsNow.query_plan_hash AS NVARCHAR(100)) +
            @LineFeed AS Details,
            'See the URL for tuning tips on why this query may be consuming resources.' AS HowToStopIt,
            qp.query_plan,
            QueryText = SUBSTRING(st.text,
                 (qsNow.statement_start_offset / 2) + 1,
                 ((CASE qsNow.statement_end_offset
                   WHEN -1 THEN DATALENGTH(st.text)
                   ELSE qsNow.statement_end_offset
                   END - qsNow.statement_start_offset) / 2) + 1),
            qsNow.ID AS QueryStatsNowID,
            qsFirst.ID AS QueryStatsFirstID,
            qsNow.plan_handle AS PlanHandle
            FROM #QueryStats qsNow
                INNER JOIN #QueryStats qsTotal ON qsTotal.Pass = 0
                LEFT OUTER JOIN #QueryStats qsFirst ON qsNow.[sql_handle] = qsFirst.[sql_handle] AND qsNow.statement_start_offset = qsFirst.statement_start_offset AND qsNow.statement_end_offset = qsFirst.statement_end_offset AND qsNow.plan_generation_num = qsFirst.plan_generation_num AND qsNow.plan_handle = qsFirst.plan_handle AND qsFirst.Pass = 1
                CROSS APPLY sys.dm_exec_sql_text(qsNow.sql_handle) AS st
                CROSS APPLY sys.dm_exec_query_plan(qsNow.plan_handle) AS qp
            WHERE qsNow.Points > 0 AND st.text IS NOT NULL AND qp.query_plan IS NOT NULL

            UPDATE #BlitzFirstResults
                SET DatabaseID = CAST(attr.value AS INT),
                DatabaseName = DB_NAME(CAST(attr.value AS INT))
            FROM #BlitzFirstResults
                CROSS APPLY sys.dm_exec_plan_attributes(#BlitzFirstResults.PlanHandle) AS attr
            WHERE attr.attribute = 'dbid'


        END /* IF DATEDIFF(ss, @FinishSampleTime, SYSDATETIMEOFFSET()) > 10 AND @CheckProcedureCache = 1 */


	RAISERROR('Analyzing changes between first and second passes of DMVs',10,1) WITH NOWAIT;

    /* Wait Stats - CheckID 6 */
    /* Compare the current wait stats to the sample we took at the start, and insert the top 10 waits. */
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt, DetailsInt)
    SELECT TOP 10 6 AS CheckID,
        200 AS Priority,
        'Wait Stats' AS FindingGroup,
        wNow.wait_type AS Finding, /* IF YOU CHANGE THIS, STUFF WILL BREAK. Other checks look for wait type names in the Finding field. See checks 11, 12 as example. */
        N'http://www.brentozar.com/sql/wait-stats/#' + wNow.wait_type AS URL,
        'For ' + CAST(((wNow.wait_time_ms - COALESCE(wBase.wait_time_ms,0)) / 1000) AS NVARCHAR(100)) + ' seconds over the last ' + CASE @Seconds WHEN 0 THEN (CAST(DATEDIFF(dd,@StartSampleTime,@FinishSampleTime) AS NVARCHAR(10)) + ' days') ELSE (CAST(@Seconds AS NVARCHAR(10)) + ' seconds') END + ', SQL Server was waiting on this particular bottleneck.' + @LineFeed + @LineFeed AS Details,
        'See the URL for more details on how to mitigate this wait type.' AS HowToStopIt,
        ((wNow.wait_time_ms - COALESCE(wBase.wait_time_ms,0)) / 1000) AS DetailsInt
    FROM #WaitStats wNow
    LEFT OUTER JOIN #WaitStats wBase ON wNow.wait_type = wBase.wait_type AND wNow.SampleTime > wBase.SampleTime
    WHERE wNow.wait_time_ms > (wBase.wait_time_ms + (.5 * (DATEDIFF(ss,@StartSampleTime,@FinishSampleTime)) * 1000)) /* Only look for things we've actually waited on for half of the time or more */
    ORDER BY (wNow.wait_time_ms - COALESCE(wBase.wait_time_ms,0)) DESC;

    /* Server Performance - Poison Wait Detected - CheckID 30 */
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt, DetailsInt)
    SELECT 30 AS CheckID,
        10 AS Priority,
        'Server Performance' AS FindingGroup,
        'Poison Wait Detected: ' + wNow.wait_type AS Finding,
        N'http://www.brentozar.com/go/poison/#' + wNow.wait_type AS URL,
        'For ' + CAST(((wNow.wait_time_ms - COALESCE(wBase.wait_time_ms,0)) / 1000) AS NVARCHAR(100)) + ' seconds over the last ' + CASE @Seconds WHEN 0 THEN (CAST(DATEDIFF(dd,@StartSampleTime,@FinishSampleTime) AS NVARCHAR(10)) + ' days') ELSE (CAST(@Seconds AS NVARCHAR(10)) + ' seconds') END + ', SQL Server was waiting on this particular bottleneck.' + @LineFeed + @LineFeed AS Details,
        'See the URL for more details on how to mitigate this wait type.' AS HowToStopIt,
        ((wNow.wait_time_ms - COALESCE(wBase.wait_time_ms,0)) / 1000) AS DetailsInt
    FROM #WaitStats wNow
    LEFT OUTER JOIN #WaitStats wBase ON wNow.wait_type = wBase.wait_type AND wNow.SampleTime > wBase.SampleTime
    WHERE wNow.wait_type IN ('IO_QUEUE_LIMIT', 'IO_RETRY', 'LOG_RATE_GOVERNOR', 'PREEMPTIVE_DEBUG', 'RESMGR_THROTTLED', 'RESOURCE_SEMAPHORE', 'RESOURCE_SEMAPHORE_QUERY_COMPILE','SE_REPL_CATCHUP_THROTTLE','SE_REPL_COMMIT_ACK','SE_REPL_COMMIT_TURN','SE_REPL_ROLLBACK_ACK','SE_REPL_SLOW_SECONDARY_THROTTLE','THREADPOOL') AND wNow.wait_time_ms > wBase.wait_time_ms;


    /* Server Performance - Slow Data File Reads - CheckID 11 */
	IF EXISTS (SELECT * FROM #BlitzFirstResults WHERE Finding LIKE 'PAGEIOLATCH%')
	BEGIN
		INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt, DatabaseID, DatabaseName)
		SELECT TOP 10 11 AS CheckID,
			50 AS Priority,
			'Server Performance' AS FindingGroup,
			'Slow Data File Reads' AS Finding,
			'http://www.BrentOzar.com/go/slow/' AS URL,
			'Your server is experiencing PAGEIOLATCH% waits due to slow data file reads. This file is one of the reasons why.' + @LineFeed
				+ 'File: ' + fNow.PhysicalName + @LineFeed
				+ 'Number of reads during the sample: ' + CAST((fNow.num_of_reads - fBase.num_of_reads) AS NVARCHAR(20)) + @LineFeed
				+ 'Seconds spent waiting on storage for these reads: ' + CAST(((fNow.io_stall_read_ms - fBase.io_stall_read_ms) / 1000.0) AS NVARCHAR(20)) + @LineFeed
				+ 'Average read latency during the sample: ' + CAST(((fNow.io_stall_read_ms - fBase.io_stall_read_ms) / (fNow.num_of_reads - fBase.num_of_reads) ) AS NVARCHAR(20)) + ' milliseconds' + @LineFeed
				+ 'Microsoft guidance for data file read speed: 20ms or less.' + @LineFeed + @LineFeed AS Details,
			'See the URL for more details on how to mitigate this wait type.' AS HowToStopIt,
			fNow.DatabaseID,
			fNow.DatabaseName
		FROM #FileStats fNow
		INNER JOIN #FileStats fBase ON fNow.DatabaseID = fBase.DatabaseID AND fNow.FileID = fBase.FileID AND fNow.SampleTime > fBase.SampleTime AND fNow.num_of_reads > fBase.num_of_reads AND fNow.io_stall_read_ms > (fBase.io_stall_read_ms + 1000)
		WHERE (fNow.io_stall_read_ms - fBase.io_stall_read_ms) / (fNow.num_of_reads - fBase.num_of_reads) >= @FileLatencyThresholdMS
			AND fNow.TypeDesc = 'ROWS'
		ORDER BY (fNow.io_stall_read_ms - fBase.io_stall_read_ms) / (fNow.num_of_reads - fBase.num_of_reads) DESC;
	END	

    /* Server Performance - Slow Log File Writes - CheckID 12 */
	IF EXISTS (SELECT * FROM #BlitzFirstResults WHERE Finding LIKE 'WRITELOG%')
	BEGIN
		INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt, DatabaseID, DatabaseName)
		SELECT TOP 10 12 AS CheckID,
			50 AS Priority,
			'Server Performance' AS FindingGroup,
			'Slow Log File Writes' AS Finding,
			'http://www.BrentOzar.com/go/slow/' AS URL,
			'Your server is experiencing WRITELOG waits due to slow log file writes. This file is one of the reasons why.' + @LineFeed
				+ 'File: ' + fNow.PhysicalName + @LineFeed
				+ 'Number of writes during the sample: ' + CAST((fNow.num_of_writes - fBase.num_of_writes) AS NVARCHAR(20)) + @LineFeed
				+ 'Seconds spent waiting on storage for these writes: ' + CAST(((fNow.io_stall_write_ms - fBase.io_stall_write_ms) / 1000.0) AS NVARCHAR(20)) + @LineFeed
				+ 'Average write latency during the sample: ' + CAST(((fNow.io_stall_write_ms - fBase.io_stall_write_ms) / (fNow.num_of_writes - fBase.num_of_writes) ) AS NVARCHAR(20)) + ' milliseconds' + @LineFeed
				+ 'Microsoft guidance for log file write speed: 3ms or less.' + @LineFeed + @LineFeed AS Details,
			'See the URL for more details on how to mitigate this wait type.' AS HowToStopIt,
			fNow.DatabaseID,
			fNow.DatabaseName
		FROM #FileStats fNow
		INNER JOIN #FileStats fBase ON fNow.DatabaseID = fBase.DatabaseID AND fNow.FileID = fBase.FileID AND fNow.SampleTime > fBase.SampleTime AND fNow.num_of_writes > fBase.num_of_writes AND fNow.io_stall_write_ms > (fBase.io_stall_write_ms + 1000)
		WHERE (fNow.io_stall_write_ms - fBase.io_stall_write_ms) / (fNow.num_of_writes - fBase.num_of_writes) >= @FileLatencyThresholdMS
			AND fNow.TypeDesc = 'LOG'
		ORDER BY (fNow.io_stall_write_ms - fBase.io_stall_write_ms) / (fNow.num_of_writes - fBase.num_of_writes) DESC;
	END


    /* SQL Server Internal Maintenance - Log File Growing - CheckID 13 */
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt)
    SELECT 13 AS CheckID,
        1 AS Priority,
        'SQL Server Internal Maintenance' AS FindingGroup,
        'Log File Growing' AS Finding,
        'http://www.BrentOzar.com/askbrent/file-growing/' AS URL,
        'Number of growths during the sample: ' + CAST(ps.value_delta AS NVARCHAR(20)) + @LineFeed
            + 'Determined by sampling Perfmon counter ' + ps.object_name + ' - ' + ps.counter_name + @LineFeed AS Details,
        'Pre-grow data and log files during maintenance windows so that they do not grow during production loads. See the URL for more details.'  AS HowToStopIt
    FROM #PerfmonStats ps
    WHERE ps.Pass = 2
        AND object_name = @ServiceName + ':Databases'
        AND counter_name = 'Log Growths'
        AND value_delta > 0


    /* SQL Server Internal Maintenance - Log File Shrinking - CheckID 14 */
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt)
    SELECT 14 AS CheckID,
        1 AS Priority,
        'SQL Server Internal Maintenance' AS FindingGroup,
        'Log File Shrinking' AS Finding,
        'http://www.BrentOzar.com/askbrent/file-shrinking/' AS URL,
        'Number of shrinks during the sample: ' + CAST(ps.value_delta AS NVARCHAR(20)) + @LineFeed
            + 'Determined by sampling Perfmon counter ' + ps.object_name + ' - ' + ps.counter_name + @LineFeed AS Details,
        'Pre-grow data and log files during maintenance windows so that they do not grow during production loads. See the URL for more details.' AS HowToStopIt
    FROM #PerfmonStats ps
    WHERE ps.Pass = 2
        AND object_name = @ServiceName + ':Databases'
        AND counter_name = 'Log Shrinks'
        AND value_delta > 0

    /* Query Problems - Compilations/Sec High - CheckID 15 */
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt)
    SELECT 15 AS CheckID,
        50 AS Priority,
        'Query Problems' AS FindingGroup,
        'Compilations/Sec High' AS Finding,
        'http://www.BrentOzar.com/askbrent/compilations/' AS URL,
        'Number of batch requests during the sample: ' + CAST(ps.value_delta AS NVARCHAR(20)) + @LineFeed
            + 'Number of compilations during the sample: ' + CAST(psComp.value_delta AS NVARCHAR(20)) + @LineFeed
            + 'For OLTP environments, Microsoft recommends that 90% of batch requests should hit the plan cache, and not be compiled from scratch. We are exceeding that threshold.' + @LineFeed AS Details,
        'To find the queries that are compiling, start with:' + @LineFeed
            + 'sp_BlitzCache @SortOrder = ''recent compilations''' + @LineFeed
            + 'If dynamic SQL or non-parameterized strings are involved, consider enabling Forced Parameterization. See the URL for more details.' AS HowToStopIt
    FROM #PerfmonStats ps
        INNER JOIN #PerfmonStats psComp ON psComp.Pass = 2 AND psComp.object_name = @ServiceName + ':SQL Statistics' AND psComp.counter_name = 'SQL Compilations/sec' AND psComp.value_delta > 0
    WHERE ps.Pass = 2
        AND ps.object_name = @ServiceName + ':SQL Statistics'
        AND ps.counter_name = 'Batch Requests/sec'
        AND ps.value_delta > (1000 * @Seconds) /* Ignore servers sitting idle */
        AND (psComp.value_delta * 10) > ps.value_delta /* Compilations are more than 10% of batch requests per second */

    /* Query Problems - Re-Compilations/Sec High - CheckID 16 */
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt)
    SELECT 16 AS CheckID,
        50 AS Priority,
        'Query Problems' AS FindingGroup,
        'Re-Compilations/Sec High' AS Finding,
        'http://www.BrentOzar.com/askbrent/recompilations/' AS URL,
        'Number of batch requests during the sample: ' + CAST(ps.value_delta AS NVARCHAR(20)) + @LineFeed
            + 'Number of recompilations during the sample: ' + CAST(psComp.value_delta AS NVARCHAR(20)) + @LineFeed
            + 'More than 10% of our queries are being recompiled. This is typically due to statistics changing on objects.' + @LineFeed AS Details,
        'To find the queries that are being forced to recompile, start with:' + @LineFeed
            + 'sp_BlitzCache @SortOrder = ''recent compilations''' + @LineFeed
            + 'Examine those plans to find out which objects are changing so quickly that they hit the stats update threshold. See the URL for more details.' AS HowToStopIt
    FROM #PerfmonStats ps
        INNER JOIN #PerfmonStats psComp ON psComp.Pass = 2 AND psComp.object_name = @ServiceName + ':SQL Statistics' AND psComp.counter_name = 'SQL Re-Compilations/sec' AND psComp.value_delta > 0
    WHERE ps.Pass = 2
        AND ps.object_name = @ServiceName + ':SQL Statistics'
        AND ps.counter_name = 'Batch Requests/sec'
        AND ps.value_delta > (1000 * @Seconds) /* Ignore servers sitting idle */
        AND (psComp.value_delta * 10) > ps.value_delta /* Recompilations are more than 10% of batch requests per second */

    /* Table Problems - Forwarded Fetches/Sec High - CheckID 29 */
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt)
    SELECT 29 AS CheckID,
        40 AS Priority,
        'Table Problems' AS FindingGroup,
        'Forwarded Fetches/Sec High' AS Finding,
        'https://BrentOzar.com/go/fetch/' AS URL,
        CAST(ps.value_delta AS NVARCHAR(20)) + ' Forwarded Records (from SQLServer:Access Methods counter)' + @LineFeed
            + 'Check your heaps: they need to be rebuilt, or they need a clustered index applied.' + @LineFeed AS Details,
        'Rebuild your heaps. If you use Ola Hallengren maintenance scripts, those do not rebuild heaps by default: https://www.brentozar.com/archive/2016/07/fix-forwarded-records/' AS HowToStopIt
    FROM #PerfmonStats ps
        INNER JOIN #PerfmonStats psComp ON psComp.Pass = 2 AND psComp.object_name = @ServiceName + ':Access Methods' AND psComp.counter_name = 'Forwarded Records/sec' AND psComp.value_delta > 100
    WHERE ps.Pass = 2
        AND ps.object_name = @ServiceName + ':Access Methods'
        AND ps.counter_name = 'Forwarded Records/sec'
        AND ps.value_delta > (100 * @Seconds) /* Ignore servers sitting idle */


    /* In-Memory OLTP - Garbage Collection in Progress - CheckID 31 */
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt)
    SELECT 31 AS CheckID,
        50 AS Priority,
        'In-Memory OLTP' AS FindingGroup,
        'Garbage Collection in Progress' AS Finding,
        'https://BrentOzar.com/go/garbage/' AS URL,
        CAST(ps.value_delta AS NVARCHAR(50)) + ' rows processed (from SQL Server YYYY XTP Garbage Collection:Rows processed/sec counter)'  + @LineFeed 
            + 'This can happen due to memory pressure (causing In-Memory OLTP to shrink its footprint) or' + @LineFeed
            + 'due to transactional workloads that constantly insert/delete data.' AS Details,
        'Sadly, you cannot choose when garbage collection occurs. This is one of the many gotchas of Hekaton. Learn more: http://nedotter.com/archive/2016/04/row-version-lifecycle-for-in-memory-oltp/' AS HowToStopIt
    FROM #PerfmonStats ps
        INNER JOIN #PerfmonStats psComp ON psComp.Pass = 2 AND psComp.object_name LIKE '%XTP Garbage Collection' AND psComp.counter_name = 'Rows processed/sec' AND psComp.value_delta > 100
    WHERE ps.Pass = 2
        AND ps.object_name LIKE '%XTP Garbage Collection'
        AND ps.counter_name = 'Rows processed/sec'
        AND ps.value_delta > (100 * @Seconds) /* Ignore servers sitting idle */

    /* In-Memory OLTP - Transactions Aborted - CheckID 32 */
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt)
    SELECT 32 AS CheckID,
        100 AS Priority,
        'In-Memory OLTP' AS FindingGroup,
        'Transactions Aborted' AS Finding,
        'https://BrentOzar.com/go/aborted/' AS URL,
        CAST(ps.value_delta AS NVARCHAR(50)) + ' transactions aborted (from SQL Server YYYY XTP Transactions:Transactions aborted/sec counter)'  + @LineFeed 
            + 'This may indicate that data is changing, or causing folks to retry their transactions, thereby increasing load.' AS Details,
        'Dig into your In-Memory OLTP transactions to figure out which ones are failing and being retried.' AS HowToStopIt
    FROM #PerfmonStats ps
        INNER JOIN #PerfmonStats psComp ON psComp.Pass = 2 AND psComp.object_name LIKE '%XTP Transactions' AND psComp.counter_name = 'Transactions aborted/sec' AND psComp.value_delta > 100
    WHERE ps.Pass = 2
        AND ps.object_name LIKE '%XTP Transactions'
        AND ps.counter_name = 'Transactions aborted/sec'
        AND ps.value_delta > (10 * @Seconds) /* Ignore servers sitting idle */

    /* Query Problems - Suboptimal Plans/Sec High - CheckID 33 */
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt)
    SELECT 32 AS CheckID,
        100 AS Priority,
        'Query Problems' AS FindingGroup,
        'Suboptimal Plans/Sec High' AS Finding,
        'https://BrentOzar.com/go/suboptimal/' AS URL,
        CAST(ps.value_delta AS NVARCHAR(50)) + ' plans reported in the ' + CAST(ps.instance_name AS NVARCHAR(100)) + ' workload group (from Workload GroupStats:Suboptimal plans/sec counter)'  + @LineFeed 
            + 'Even if you are not using Resource Governor, it still tracks information about user queries, memory grants, etc.' AS Details,
        'Check out sp_BlitzCache to get more information about recent queries, or try sp_BlitzWho to see currently running queries.' AS HowToStopIt
    FROM #PerfmonStats ps
        INNER JOIN #PerfmonStats psComp ON psComp.Pass = 2 AND psComp.object_name = @ServiceName + ':Workload GroupStats' AND psComp.counter_name = 'Suboptimal plans/sec' AND psComp.value_delta > 100
    WHERE ps.Pass = 2
        AND ps.object_name = @ServiceName + ':Workload GroupStats' 
        AND ps.counter_name = 'Suboptimal plans/sec'
        AND ps.value_delta > (10 * @Seconds) /* Ignore servers sitting idle */



    /* Server Info - Batch Requests per Sec - CheckID 19 */
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, DetailsInt)
    SELECT 19 AS CheckID,
        250 AS Priority,
        'Server Info' AS FindingGroup,
        'Batch Requests per Sec' AS Finding,
        'http://www.BrentOzar.com/go/measure' AS URL,
        CAST(ps.value_delta / (DATEDIFF(ss, ps1.SampleTime, ps.SampleTime)) AS NVARCHAR(20)) AS Details,
        ps.value_delta / (DATEDIFF(ss, ps1.SampleTime, ps.SampleTime)) AS DetailsInt
    FROM #PerfmonStats ps
        INNER JOIN #PerfmonStats ps1 ON ps.object_name = ps1.object_name AND ps.counter_name = ps1.counter_name AND ps1.Pass = 1
    WHERE ps.Pass = 2
        AND ps.object_name = @ServiceName + ':SQL Statistics'
        AND ps.counter_name = 'Batch Requests/sec';


        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':SQL Statistics','SQL Compilations/sec', NULL)
        INSERT INTO #PerfmonCounters ([object_name],[counter_name],[instance_name]) VALUES (@ServiceName + ':SQL Statistics','SQL Re-Compilations/sec', NULL)

    /* Server Info - SQL Compilations/sec - CheckID 25 */
    IF @ExpertMode = 1
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, DetailsInt)
    SELECT 25 AS CheckID,
        250 AS Priority,
        'Server Info' AS FindingGroup,
        'SQL Compilations per Sec' AS Finding,
        'http://www.BrentOzar.com/go/measure' AS URL,
        CAST(ps.value_delta / (DATEDIFF(ss, ps1.SampleTime, ps.SampleTime)) AS NVARCHAR(20)) AS Details,
        ps.value_delta / (DATEDIFF(ss, ps1.SampleTime, ps.SampleTime)) AS DetailsInt
    FROM #PerfmonStats ps
        INNER JOIN #PerfmonStats ps1 ON ps.object_name = ps1.object_name AND ps.counter_name = ps1.counter_name AND ps1.Pass = 1
    WHERE ps.Pass = 2
        AND ps.object_name = @ServiceName + ':SQL Statistics'
        AND ps.counter_name = 'SQL Compilations/sec';

    /* Server Info - SQL Re-Compilations/sec - CheckID 26 */
    IF @ExpertMode = 1
    INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, DetailsInt)
    SELECT 26 AS CheckID,
        250 AS Priority,
        'Server Info' AS FindingGroup,
        'SQL Re-Compilations per Sec' AS Finding,
        'http://www.BrentOzar.com/go/measure' AS URL,
        CAST(ps.value_delta / (DATEDIFF(ss, ps1.SampleTime, ps.SampleTime)) AS NVARCHAR(20)) AS Details,
        ps.value_delta / (DATEDIFF(ss, ps1.SampleTime, ps.SampleTime)) AS DetailsInt
    FROM #PerfmonStats ps
        INNER JOIN #PerfmonStats ps1 ON ps.object_name = ps1.object_name AND ps.counter_name = ps1.counter_name AND ps1.Pass = 1
    WHERE ps.Pass = 2
        AND ps.object_name = @ServiceName + ':SQL Statistics'
        AND ps.counter_name = 'SQL Re-Compilations/sec';

    /* Server Info - Wait Time per Core per Sec - CheckID 20 */
    IF @Seconds > 0
    BEGIN
        WITH waits1(SampleTime, waits_ms) AS (SELECT SampleTime, SUM(ws1.wait_time_ms) FROM #WaitStats ws1 WHERE ws1.Pass = 1 GROUP BY SampleTime),
        waits2(SampleTime, waits_ms) AS (SELECT SampleTime, SUM(ws2.wait_time_ms) FROM #WaitStats ws2 WHERE ws2.Pass = 2 GROUP BY SampleTime),
        cores(cpu_count) AS (SELECT SUM(1) FROM sys.dm_os_schedulers WHERE status = 'VISIBLE ONLINE' AND is_online = 1)
        INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, URL, Details, DetailsInt)
        SELECT 19 AS CheckID,
            250 AS Priority,
            'Server Info' AS FindingGroup,
            'Wait Time per Core per Sec' AS Finding,
            'http://www.BrentOzar.com/go/measure' AS URL,
            CAST((waits2.waits_ms - waits1.waits_ms) / 1000 / i.cpu_count / DATEDIFF(ss, waits1.SampleTime, waits2.SampleTime) AS NVARCHAR(20)) AS Details,
            (waits2.waits_ms - waits1.waits_ms) / 1000 / i.cpu_count / DATEDIFF(ss, waits1.SampleTime, waits2.SampleTime) AS DetailsInt
        FROM cores i
          CROSS JOIN waits1
          CROSS JOIN waits2;
    END

    /* Server Performance - High CPU Utilization CheckID 24 */
    IF @Seconds >= 30
        BEGIN
        /* If we're waiting 30+ seconds, run this check at the end.
           We get this data from the ring buffers, and it's only updated once per minute, so might
           as well get it now - whereas if we're checking 30+ seconds, it might get updated by the
           end of our sp_BlitzFirst session. */
        INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, Details, DetailsInt, URL)
        SELECT 24, 50, 'Server Performance', 'High CPU Utilization', CAST(100 - SystemIdle AS NVARCHAR(20)) + N'%. Ring buffer details: ' + CAST(record AS NVARCHAR(4000)), 100 - SystemIdle, 'http://www.BrentOzar.com/go/cpu'
            FROM (
                SELECT record,
                    record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') AS SystemIdle
                FROM (
                    SELECT TOP 1 CONVERT(XML, record) AS record
                    FROM sys.dm_os_ring_buffers
                    WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
                    AND record LIKE '%<SystemHealth>%'
                    ORDER BY timestamp DESC) AS rb
            ) AS y
            WHERE 100 - SystemIdle >= 50

        INSERT INTO #BlitzFirstResults (CheckID, Priority, FindingsGroup, Finding, Details, DetailsInt, URL)
        SELECT 23, 250, 'Server Info', 'CPU Utilization', CAST(100 - SystemIdle AS NVARCHAR(20)) + N'%. Ring buffer details: ' + CAST(record AS NVARCHAR(4000)), 100 - SystemIdle, 'http://www.BrentOzar.com/go/cpu'
            FROM (
                SELECT record,
                    record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') AS SystemIdle
                FROM (
                    SELECT TOP 1 CONVERT(XML, record) AS record
                    FROM sys.dm_os_ring_buffers
                    WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
                    AND record LIKE '%<SystemHealth>%'
                    ORDER BY timestamp DESC) AS rb
            ) AS y

        END /* IF @Seconds < 30 */

	RAISERROR('Analysis finished, outputting results',10,1) WITH NOWAIT;


    /* If we didn't find anything, apologize. */
    IF NOT EXISTS (SELECT * FROM #BlitzFirstResults WHERE Priority < 250)
    BEGIN

        INSERT  INTO #BlitzFirstResults
                ( CheckID ,
                  Priority ,
                  FindingsGroup ,
                  Finding ,
                  URL ,
                  Details
                )
        VALUES  ( -1 ,
                  1 ,
                  'No Problems Found' ,
                  'From Your Community Volunteers' ,
                  'http://FirstResponderKit.org/' ,
                  'Try running our more in-depth checks with sp_Blitz, or there may not be an unusual SQL Server performance problem. '
                );

    END /*IF NOT EXISTS (SELECT * FROM #BlitzFirstResults) */

        /* Add credits for the nice folks who put so much time into building and maintaining this for free: */
        INSERT  INTO #BlitzFirstResults
                ( CheckID ,
                  Priority ,
                  FindingsGroup ,
                  Finding ,
                  URL ,
                  Details
                )
        VALUES  ( -1 ,
                  255 ,
                  'Thanks!' ,
                  'From Your Community Volunteers' ,
                  'http://FirstResponderKit.org/' ,
                  'To get help or add your own contributions, join us at http://FirstResponderKit.org.'
                );

        INSERT  INTO #BlitzFirstResults
                ( CheckID ,
                  Priority ,
                  FindingsGroup ,
                  Finding ,
                  URL ,
                  Details

                )
        VALUES  ( -1 ,
                  0 ,
                  'sp_BlitzFirst ' + CAST(CONVERT(DATETIMEOFFSET, @VersionDate, 102) AS VARCHAR(100)),
                  'From Your Community Volunteers' ,
                  'http://FirstResponderKit.org/' ,
                  'We hope you found this tool useful.'
                );

                /* Outdated sp_BlitzFirst - sp_BlitzFirst is Over 6 Months Old */
                IF DATEDIFF(MM, @VersionDate, SYSDATETIMEOFFSET()) > 6
                    BEGIN
                        INSERT  INTO #BlitzFirstResults
                                ( CheckID ,
                                    Priority ,
                                    FindingsGroup ,
                                    Finding ,
                                    URL ,
                                    Details
                                )
                                SELECT 27 AS CheckID ,
                                        0 AS Priority ,
                                        'Outdated sp_BlitzFirst' AS FindingsGroup ,
                                        'sp_BlitzFirst is Over 6 Months Old' AS Finding ,
                                        'http://FirstResponderKit.org/' AS URL ,
                                        'Some things get better with age, like fine wine and your T-SQL. However, sp_BlitzFirst is not one of those things - time to go download the current one.' AS Details
                    END



    /* @OutputTableName lets us export the results to a permanent table */
    IF @OutputDatabaseName IS NOT NULL
        AND @OutputSchemaName IS NOT NULL
        AND @OutputTableName IS NOT NULL
        AND @OutputTableName NOT LIKE '#%'
        AND EXISTS ( SELECT *
                     FROM   sys.databases
                     WHERE  QUOTENAME([name]) = @OutputDatabaseName)
    BEGIN
        SET @StringToExecute = 'USE '
            + @OutputDatabaseName
            + '; IF EXISTS(SELECT * FROM '
            + @OutputDatabaseName
            + '.INFORMATION_SCHEMA.SCHEMATA WHERE QUOTENAME(SCHEMA_NAME) = '''
            + @OutputSchemaName
            + ''') AND NOT EXISTS (SELECT * FROM '
            + @OutputDatabaseName
            + '.INFORMATION_SCHEMA.TABLES WHERE QUOTENAME(TABLE_SCHEMA) = '''
            + @OutputSchemaName + ''' AND QUOTENAME(TABLE_NAME) = '''
            + @OutputTableName + ''') CREATE TABLE '
            + @OutputSchemaName + '.'
            + @OutputTableName
            + ' (ID INT IDENTITY(1,1) NOT NULL,
                ServerName NVARCHAR(128),
                CheckDate DATETIMEOFFSET,
                CheckID INT NOT NULL,
                Priority TINYINT NOT NULL,
                FindingsGroup VARCHAR(50) NOT NULL,
                Finding VARCHAR(200) NOT NULL,
                URL VARCHAR(200) NOT NULL,
                Details NVARCHAR(4000) NULL,
                HowToStopIt [XML] NULL,
                QueryPlan [XML] NULL,
                QueryText NVARCHAR(MAX) NULL,
                StartTime DATETIMEOFFSET NULL,
                LoginName NVARCHAR(128) NULL,
                NTUserName NVARCHAR(128) NULL,
                OriginalLoginName NVARCHAR(128) NULL,
                ProgramName NVARCHAR(128) NULL,
                HostName NVARCHAR(128) NULL,
                DatabaseID INT NULL,
                DatabaseName NVARCHAR(128) NULL,
                OpenTransactionCount INT NULL,
                DetailsInt INT NULL,
                CONSTRAINT [PK_' + CAST(NEWID() AS CHAR(36)) + '] PRIMARY KEY CLUSTERED (ID ASC));'

        EXEC(@StringToExecute);
        SET @StringToExecute = N' IF EXISTS(SELECT * FROM '
            + @OutputDatabaseName
            + '.INFORMATION_SCHEMA.SCHEMATA WHERE QUOTENAME(SCHEMA_NAME) = '''
            + @OutputSchemaName + ''') INSERT '
            + @OutputDatabaseName + '.'
            + @OutputSchemaName + '.'
            + @OutputTableName
            + ' (ServerName, CheckDate, CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt, QueryPlan, QueryText, StartTime, LoginName, NTUserName, OriginalLoginName, ProgramName, HostName, DatabaseID, DatabaseName, OpenTransactionCount, DetailsInt) SELECT '''
            + CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128))
            + ''', ''' + (CONVERT(NVARCHAR(100), @StartSampleTime, 121)) + ''', CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt, QueryPlan, QueryText, StartTime, LoginName, NTUserName, OriginalLoginName, ProgramName, HostName, DatabaseID, DatabaseName, OpenTransactionCount, DetailsInt FROM #BlitzFirstResults ORDER BY Priority , FindingsGroup , Finding , Details';
        EXEC(@StringToExecute);
    END
    ELSE IF (SUBSTRING(@OutputTableName, 2, 2) = '##')
    BEGIN
        SET @StringToExecute = N' IF (OBJECT_ID(''tempdb..'
            + @OutputTableName
            + ''') IS NULL) CREATE TABLE '
            + @OutputTableName
            + ' (ID INT IDENTITY(1,1) NOT NULL,
                ServerName NVARCHAR(128),
                CheckDate DATETIMEOFFSET,
                CheckID INT NOT NULL,
                Priority TINYINT NOT NULL,
                FindingsGroup VARCHAR(50) NOT NULL,
                Finding VARCHAR(200) NOT NULL,
                URL VARCHAR(200) NOT NULL,
                Details NVARCHAR(4000) NULL,
                HowToStopIt [XML] NULL,
                QueryPlan [XML] NULL,
                QueryText NVARCHAR(MAX) NULL,
                StartTime DATETIMEOFFSET NULL,
                LoginName NVARCHAR(128) NULL,
                NTUserName NVARCHAR(128) NULL,
                OriginalLoginName NVARCHAR(128) NULL,
                ProgramName NVARCHAR(128) NULL,
                HostName NVARCHAR(128) NULL,
                DatabaseID INT NULL,
                DatabaseName NVARCHAR(128) NULL,
                OpenTransactionCount INT NULL,
                DetailsInt INT NULL,
                CONSTRAINT [PK_' + CAST(NEWID() AS CHAR(36)) + '] PRIMARY KEY CLUSTERED (ID ASC));'
            + ' INSERT '
            + @OutputTableName
            + ' (ServerName, CheckDate, CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt, QueryPlan, QueryText, StartTime, LoginName, NTUserName, OriginalLoginName, ProgramName, HostName, DatabaseID, DatabaseName, OpenTransactionCount, DetailsInt) SELECT '''
            + CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128))
            + ''', ''' + CONVERT(NVARCHAR(100), @StartSampleTime, 121) + ''', CheckID, Priority, FindingsGroup, Finding, URL, Details, HowToStopIt, QueryPlan, QueryText, StartTime, LoginName, NTUserName, OriginalLoginName, ProgramName, HostName, DatabaseID, DatabaseName, OpenTransactionCount, DetailsInt FROM #BlitzFirstResults ORDER BY Priority , FindingsGroup , Finding , Details';
        EXEC(@StringToExecute);
    END
    ELSE IF (SUBSTRING(@OutputTableName, 2, 1) = '#')
    BEGIN
        RAISERROR('Due to the nature of Dymamic SQL, only global (i.e. double pound (##)) temp tables are supported for @OutputTableName', 16, 0)
    END

    /* @OutputTableNameFileStats lets us export the results to a permanent table */
    IF @OutputDatabaseName IS NOT NULL
        AND @OutputSchemaName IS NOT NULL
        AND @OutputTableNameFileStats IS NOT NULL
        AND @OutputTableNameFileStats NOT LIKE '#%'
        AND EXISTS ( SELECT *
                     FROM   sys.databases
                     WHERE  QUOTENAME([name]) = @OutputDatabaseName)
    BEGIN
        /* Create the table */
        SET @StringToExecute = 'USE '
            + @OutputDatabaseName
            + '; IF EXISTS(SELECT * FROM '
            + @OutputDatabaseName
            + '.INFORMATION_SCHEMA.SCHEMATA WHERE QUOTENAME(SCHEMA_NAME) = '''
            + @OutputSchemaName
            + ''') AND NOT EXISTS (SELECT * FROM '
            + @OutputDatabaseName
            + '.INFORMATION_SCHEMA.TABLES WHERE QUOTENAME(TABLE_SCHEMA) = '''
            + @OutputSchemaName + ''' AND QUOTENAME(TABLE_NAME) = '''
            + @OutputTableNameFileStats + ''') CREATE TABLE '
            + @OutputSchemaName + '.'
            + @OutputTableNameFileStats
            + ' (ID INT IDENTITY(1,1) NOT NULL,
                ServerName NVARCHAR(128),
                CheckDate DATETIMEOFFSET,
                DatabaseID INT NOT NULL,
                FileID INT NOT NULL,
                DatabaseName NVARCHAR(256) ,
                FileLogicalName NVARCHAR(256) ,
                TypeDesc NVARCHAR(60) ,
                SizeOnDiskMB BIGINT ,
                io_stall_read_ms BIGINT ,
                num_of_reads BIGINT ,
                bytes_read BIGINT ,
                io_stall_write_ms BIGINT ,
                num_of_writes BIGINT ,
                bytes_written BIGINT,
                PhysicalName NVARCHAR(520) ,
                CONSTRAINT [PK_' + CAST(NEWID() AS CHAR(36)) + '] PRIMARY KEY CLUSTERED (ID ASC));'
        EXEC(@StringToExecute);

        /* Create the view */
        SET @ObjectFullName = @OutputDatabaseName + N'.' + @OutputSchemaName + N'.' +  @OutputTableNameFileStats_View;
        IF OBJECT_ID(@ObjectFullName) IS NULL
            BEGIN
            SET @StringToExecute = 'USE '
                + @OutputDatabaseName
                + '; EXEC (''CREATE VIEW '
                + @OutputSchemaName + '.'
                + @OutputTableNameFileStats_View + ' AS ' + @LineFeed
                + 'SELECT f.ServerName, f.CheckDate, f.DatabaseID, f.DatabaseName, f.FileID, f.FileLogicalName, f.TypeDesc, f.PhysicalName, f.SizeOnDiskMB' + @LineFeed
                + ', DATEDIFF(ss, fPrior.CheckDate, f.CheckDate) AS ElapsedSeconds' + @LineFeed
                + ', (f.SizeOnDiskMB - fPrior.SizeOnDiskMB) AS SizeOnDiskMBgrowth' + @LineFeed
                + ', (f.io_stall_read_ms - fPrior.io_stall_read_ms) AS io_stall_read_ms' + @LineFeed
                + ', io_stall_read_ms_average = CASE WHEN (f.num_of_reads - fPrior.num_of_reads) = 0 THEN 0 ELSE (f.io_stall_read_ms - fPrior.io_stall_read_ms) / (f.num_of_reads - fPrior.num_of_reads) END' + @LineFeed
                + ', (f.num_of_reads - fPrior.num_of_reads) AS num_of_reads' + @LineFeed
                + ', (f.bytes_read - fPrior.bytes_read) / 1024.0 / 1024.0 AS megabytes_read' + @LineFeed
                + ', (f.io_stall_write_ms - fPrior.io_stall_write_ms) AS io_stall_write_ms' + @LineFeed
                + ', io_stall_write_ms_average = CASE WHEN (f.num_of_writes - fPrior.num_of_writes) = 0 THEN 0 ELSE (f.io_stall_write_ms - fPrior.io_stall_write_ms) / (f.num_of_writes - fPrior.num_of_writes) END' + @LineFeed
                + ', (f.num_of_writes - fPrior.num_of_writes) AS num_of_writes' + @LineFeed
                + ', (f.bytes_written - fPrior.bytes_written) / 1024.0 / 1024.0 AS megabytes_written' + @LineFeed
                + 'FROM ' + @OutputSchemaName + '.' + @OutputTableNameFileStats + ' f' + @LineFeed
                + 'INNER JOIN ' + @OutputSchemaName + '.' + @OutputTableNameFileStats + ' fPrior ON f.ServerName = fPrior.ServerName AND f.DatabaseID = fPrior.DatabaseID AND f.FileID = fPrior.FileID AND f.CheckDate > fPrior.CheckDate' + @LineFeed
                + 'LEFT OUTER JOIN ' + @OutputSchemaName + '.' + @OutputTableNameFileStats + ' fMiddle ON f.ServerName = fMiddle.ServerName AND f.DatabaseID = fMiddle.DatabaseID AND f.FileID = fMiddle.FileID AND f.CheckDate > fMiddle.CheckDate AND fMiddle.CheckDate > fPrior.CheckDate' + @LineFeed
                + 'WHERE fMiddle.ID IS NULL;'')'
            EXEC(@StringToExecute);
            END

        SET @StringToExecute = N' IF EXISTS(SELECT * FROM '
            + @OutputDatabaseName
            + '.INFORMATION_SCHEMA.SCHEMATA WHERE QUOTENAME(SCHEMA_NAME) = '''
            + @OutputSchemaName + ''') INSERT '
            + @OutputDatabaseName + '.'
            + @OutputSchemaName + '.'
            + @OutputTableNameFileStats
            + ' (ServerName, CheckDate, DatabaseID, FileID, DatabaseName, FileLogicalName, TypeDesc, SizeOnDiskMB, io_stall_read_ms, num_of_reads, bytes_read, io_stall_write_ms, num_of_writes, bytes_written, PhysicalName) SELECT '''
            + CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128))
            + ''', ''' + CONVERT(NVARCHAR(100), @StartSampleTime, 121) + ''', '
            + 'DatabaseID, FileID, DatabaseName, FileLogicalName, TypeDesc, SizeOnDiskMB, io_stall_read_ms, num_of_reads, bytes_read, io_stall_write_ms, num_of_writes, bytes_written, PhysicalName FROM #FileStats WHERE Pass = 2';
        EXEC(@StringToExecute);
    END
    ELSE IF (SUBSTRING(@OutputTableNameFileStats, 2, 2) = '##')
    BEGIN
        SET @StringToExecute = N' IF (OBJECT_ID(''tempdb..'
            + @OutputTableNameFileStats
            + ''') IS NULL) CREATE TABLE '
            + @OutputTableNameFileStats
            + ' (ID INT IDENTITY(1,1) NOT NULL,
                ServerName NVARCHAR(128),
                CheckDate DATETIMEOFFSET,
                DatabaseID INT NOT NULL,
                FileID INT NOT NULL,
                DatabaseName NVARCHAR(256) ,
                FileLogicalName NVARCHAR(256) ,
                TypeDesc NVARCHAR(60) ,
                SizeOnDiskMB BIGINT ,
                io_stall_read_ms BIGINT ,
                num_of_reads BIGINT ,
                bytes_read BIGINT ,
                io_stall_write_ms BIGINT ,
                num_of_writes BIGINT ,
                bytes_written BIGINT,
                PhysicalName NVARCHAR(520) ,
                DetailsInt INT NULL,
                CONSTRAINT [PK_' + CAST(NEWID() AS CHAR(36)) + '] PRIMARY KEY CLUSTERED (ID ASC));'
            + ' INSERT '
            + @OutputTableNameFileStats
            + ' (ServerName, CheckDate, DatabaseID, FileID, DatabaseName, FileLogicalName, TypeDesc, SizeOnDiskMB, io_stall_read_ms, num_of_reads, bytes_read, io_stall_write_ms, num_of_writes, bytes_written, PhysicalName) SELECT '''
            + CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128))
            + ''', ''' + CONVERT(NVARCHAR(100), @StartSampleTime, 121) + ''', '
            + 'DatabaseID, FileID, DatabaseName, FileLogicalName, TypeDesc, SizeOnDiskMB, io_stall_read_ms, num_of_reads, bytes_read, io_stall_write_ms, num_of_writes, bytes_written, PhysicalName FROM #FileStats WHERE Pass = 2';
        EXEC(@StringToExecute);
    END
    ELSE IF (SUBSTRING(@OutputTableNameFileStats, 2, 1) = '#')
    BEGIN
        RAISERROR('Due to the nature of Dymamic SQL, only global (i.e. double pound (##)) temp tables are supported for @OutputTableName', 16, 0)
    END


    /* @OutputTableNamePerfmonStats lets us export the results to a permanent table */
    IF @OutputDatabaseName IS NOT NULL
        AND @OutputSchemaName IS NOT NULL
        AND @OutputTableNamePerfmonStats IS NOT NULL
        AND @OutputTableNamePerfmonStats NOT LIKE '#%'
        AND EXISTS ( SELECT *
                     FROM   sys.databases
                     WHERE  QUOTENAME([name]) = @OutputDatabaseName)
    BEGIN
        /* Create the table */
        SET @StringToExecute = 'USE '
            + @OutputDatabaseName
            + '; IF EXISTS(SELECT * FROM '
            + @OutputDatabaseName
            + '.INFORMATION_SCHEMA.SCHEMATA WHERE QUOTENAME(SCHEMA_NAME) = '''
            + @OutputSchemaName
            + ''') AND NOT EXISTS (SELECT * FROM '
            + @OutputDatabaseName
            + '.INFORMATION_SCHEMA.TABLES WHERE QUOTENAME(TABLE_SCHEMA) = '''
            + @OutputSchemaName + ''' AND QUOTENAME(TABLE_NAME) = '''
            + @OutputTableNamePerfmonStats + ''') CREATE TABLE '
            + @OutputSchemaName + '.'
            + @OutputTableNamePerfmonStats
            + ' (ID INT IDENTITY(1,1) NOT NULL,
                ServerName NVARCHAR(128),
                CheckDate DATETIMEOFFSET,
                [object_name] NVARCHAR(128) NOT NULL,
                [counter_name] NVARCHAR(128) NOT NULL,
                [instance_name] NVARCHAR(128) NULL,
                [cntr_value] BIGINT NULL,
                [cntr_type] INT NOT NULL,
                [value_delta] BIGINT NULL,
                [value_per_second] DECIMAL(18,2) NULL,
                CONSTRAINT [PK_' + CAST(NEWID() AS CHAR(36)) + '] PRIMARY KEY CLUSTERED (ID ASC));'
        EXEC(@StringToExecute);

        /* Create the view */
        SET @ObjectFullName = @OutputDatabaseName + N'.' + @OutputSchemaName + N'.' +  @OutputTableNamePerfmonStats_View;
        IF OBJECT_ID(@ObjectFullName) IS NULL
            BEGIN
            SET @StringToExecute = 'USE '
                + @OutputDatabaseName
                + '; EXEC (''CREATE VIEW '
                + @OutputSchemaName + '.'
                + @OutputTableNamePerfmonStats_View + ' AS ' + @LineFeed
                + 'SELECT p.ServerName, p.CheckDate, p.object_name, p.counter_name, p.instance_name' + @LineFeed
                + ', DATEDIFF(ss, pPrior.CheckDate, p.CheckDate) AS ElapsedSeconds' + @LineFeed
                + ', p.cntr_value' + @LineFeed
                + ', p.cntr_type' + @LineFeed
                + ', (p.cntr_value - pPrior.cntr_value) AS cntr_delta' + @LineFeed
                + 'FROM ' + @OutputSchemaName + '.' + @OutputTableNamePerfmonStats + ' p' + @LineFeed
                + 'INNER JOIN ' + @OutputSchemaName + '.' + @OutputTableNamePerfmonStats + ' pPrior ON p.ServerName = pPrior.ServerName AND p.object_name = pPrior.object_name AND p.counter_name = pPrior.counter_name AND p.instance_name = pPrior.instance_name AND p.CheckDate > pPrior.CheckDate' + @LineFeed
                + 'LEFT OUTER JOIN ' + @OutputSchemaName + '.' + @OutputTableNamePerfmonStats + ' pMiddle ON p.ServerName = pMiddle.ServerName AND p.object_name = pMiddle.object_name AND p.counter_name = pMiddle.counter_name AND p.instance_name = pMiddle.instance_name AND p.CheckDate > pMiddle.CheckDate AND pMiddle.CheckDate > pPrior.CheckDate' + @LineFeed
                + 'WHERE pMiddle.ID IS NULL;'')'
            EXEC(@StringToExecute);
            END;

        SET @StringToExecute = N' IF EXISTS(SELECT * FROM '
            + @OutputDatabaseName
            + '.INFORMATION_SCHEMA.SCHEMATA WHERE QUOTENAME(SCHEMA_NAME) = '''
            + @OutputSchemaName + ''') INSERT '
            + @OutputDatabaseName + '.'
            + @OutputSchemaName + '.'
            + @OutputTableNamePerfmonStats
            + ' (ServerName, CheckDate, object_name, counter_name, instance_name, cntr_value, cntr_type, value_delta, value_per_second) SELECT '''
            + CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128))
            + ''', ''' + CONVERT(NVARCHAR(100), @StartSampleTime, 121) + ''', '
            + 'object_name, counter_name, instance_name, cntr_value, cntr_type, value_delta, value_per_second FROM #PerfmonStats WHERE Pass = 2';
        EXEC(@StringToExecute);

    END
    ELSE IF (SUBSTRING(@OutputTableNamePerfmonStats, 2, 2) = '##')
    BEGIN
        SET @StringToExecute = N' IF (OBJECT_ID(''tempdb..'
            + @OutputTableNamePerfmonStats
            + ''') IS NULL) CREATE TABLE '
            + @OutputTableNamePerfmonStats
            + ' (ID INT IDENTITY(1,1) NOT NULL,
                ServerName NVARCHAR(128),
                CheckDate DATETIMEOFFSET,
                [object_name] NVARCHAR(128) NOT NULL,
                [counter_name] NVARCHAR(128) NOT NULL,
                [instance_name] NVARCHAR(128) NULL,
                [cntr_value] BIGINT NULL,
                [cntr_type] INT NOT NULL,
                [value_delta] BIGINT NULL,
                [value_per_second] DECIMAL(18,2) NULL,
                CONSTRAINT [PK_' + CAST(NEWID() AS CHAR(36)) + '] PRIMARY KEY CLUSTERED (ID ASC));'
            + ' INSERT '
            + @OutputTableNamePerfmonStats
            + ' (ServerName, CheckDate, object_name, counter_name, instance_name, cntr_value, cntr_type, value_delta, value_per_second) SELECT '''
            + CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128))
            + ''', ''' + CONVERT(NVARCHAR(100), @StartSampleTime, 121) + ''', '
            + 'object_name, counter_name, instance_name, cntr_value, cntr_type, value_delta, value_per_second FROM #PerfmonStats WHERE Pass = 2';
        EXEC(@StringToExecute);
    END
    ELSE IF (SUBSTRING(@OutputTableNamePerfmonStats, 2, 1) = '#')
    BEGIN
        RAISERROR('Due to the nature of Dymamic SQL, only global (i.e. double pound (##)) temp tables are supported for @OutputTableName', 16, 0)
    END


    /* @OutputTableNameWaitStats lets us export the results to a permanent table */
    IF @OutputDatabaseName IS NOT NULL
        AND @OutputSchemaName IS NOT NULL
        AND @OutputTableNameWaitStats IS NOT NULL
        AND @OutputTableNameWaitStats NOT LIKE '#%'
        AND EXISTS ( SELECT *
                     FROM   sys.databases
                     WHERE  QUOTENAME([name]) = @OutputDatabaseName)
    BEGIN
        /* Create the table */
        SET @StringToExecute = 'USE '
            + @OutputDatabaseName
            + '; IF EXISTS(SELECT * FROM '
            + @OutputDatabaseName
            + '.INFORMATION_SCHEMA.SCHEMATA WHERE QUOTENAME(SCHEMA_NAME) = '''
            + @OutputSchemaName
            + ''') AND NOT EXISTS (SELECT * FROM '
            + @OutputDatabaseName
            + '.INFORMATION_SCHEMA.TABLES WHERE QUOTENAME(TABLE_SCHEMA) = '''
            + @OutputSchemaName + ''' AND QUOTENAME(TABLE_NAME) = '''
            + @OutputTableNameWaitStats + ''') CREATE TABLE '
            + @OutputSchemaName + '.'
            + @OutputTableNameWaitStats
            + ' (ID INT IDENTITY(1,1) NOT NULL,
                ServerName NVARCHAR(128),
                CheckDate DATETIMEOFFSET,
                wait_type NVARCHAR(60),
                wait_time_ms BIGINT,
                signal_wait_time_ms BIGINT,
                waiting_tasks_count BIGINT ,
                CONSTRAINT [PK_' + CAST(NEWID() AS CHAR(36)) + '] PRIMARY KEY CLUSTERED (ID));' + @LineFeed
			+ 'CREATE NONCLUSTERED INDEX IX_ServerName_wait_type_CheckDate_Includes ON ' + @OutputSchemaName + '.' + @OutputTableNameWaitStats + @LineFeed
			+ '(ServerName, wait_type, CheckDate) INCLUDE (wait_time_ms, signal_wait_time_ms, waiting_tasks_count);'

        EXEC(@StringToExecute);

        /* Create the wait stats category table */
        SET @ObjectFullName = @OutputDatabaseName + N'.' + @OutputSchemaName + N'.' +  @OutputTableNameWaitStats_Categories;
        IF OBJECT_ID(@ObjectFullName) IS NULL
            BEGIN
            SET @StringToExecute = 'USE '
                + @OutputDatabaseName
                + '; EXEC (''CREATE TABLE '
                + @OutputSchemaName + '.'
                + @OutputTableNameWaitStats_Categories + ' (WaitType NVARCHAR(60) PRIMARY KEY CLUSTERED, WaitCategory NVARCHAR(128) NOT NULL);'')'
            EXEC(@StringToExecute);
            END

		/* Make sure the wait stats category table has the current number of rows */
		SET @StringToExecute = 'USE '
            + @OutputDatabaseName
            + '; EXEC (''IF (SELECT COALESCE(SUM(1),0) FROM ' + @OutputSchemaName + '.' + @OutputTableNameWaitStats_Categories + ') <> (SELECT COALESCE(SUM(1),0) FROM ##WaitCategories)' + @LineFeed
			+ 'BEGIN ' + @LineFeed
			+ 'TRUNCATE TABLE '  + @OutputSchemaName + '.' + @OutputTableNameWaitStats_Categories + @LineFeed
			+ 'INSERT INTO ' + @OutputSchemaName + '.' + @OutputTableNameWaitStats_Categories + ' (WaitType, WaitCategory) SELECT WaitType, WaitCategory FROM ##WaitCategories;' + @LineFeed
			+ 'END'')'
        EXEC(@StringToExecute);


        /* Create the wait stats view */
        SET @ObjectFullName = @OutputDatabaseName + N'.' + @OutputSchemaName + N'.' +  @OutputTableNameWaitStats_View;
        IF OBJECT_ID(@ObjectFullName) IS NULL
            BEGIN
            SET @StringToExecute = 'USE '
                + @OutputDatabaseName
                + '; EXEC (''CREATE VIEW '
                + @OutputSchemaName + '.'
                + @OutputTableNameWaitStats_View + ' AS ' + @LineFeed
                + 'SELECT w.ServerName, w.CheckDate, w.wait_type, wc.WaitCategory' + @LineFeed
                + ', DATEDIFF(ss, wPrior.CheckDate, w.CheckDate) AS ElapsedSeconds' + @LineFeed
                + ', (w.wait_time_ms - wPrior.wait_time_ms) AS wait_time_ms_delta' + @LineFeed
                + ', (w.signal_wait_time_ms - wPrior.signal_wait_time_ms) AS signal_wait_time_ms_delta' + @LineFeed
                + ', (w.waiting_tasks_count - wPrior.waiting_tasks_count) AS waiting_tasks_count_delta' + @LineFeed
                + 'FROM ' + @OutputSchemaName + '.' + @OutputTableNameWaitStats + ' w' + @LineFeed
                + 'INNER JOIN ' + @OutputSchemaName + '.' + @OutputTableNameWaitStats + ' wPrior ON w.ServerName = wPrior.ServerName AND w.wait_type = wPrior.wait_type AND w.CheckDate > wPrior.CheckDate' + @LineFeed
                + 'LEFT OUTER JOIN ' + @OutputSchemaName + '.' + @OutputTableNameWaitStats + ' wMiddle ON w.ServerName = wMiddle.ServerName AND w.wait_type = wMiddle.wait_type AND w.CheckDate > wMiddle.CheckDate AND wMiddle.CheckDate > wPrior.CheckDate' + @LineFeed
				+ 'LEFT OUTER JOIN ' + @OutputSchemaName + '.' + @OutputTableNameWaitStats_Categories + ' wc ON w.wait_type = wc.WaitType' + @LineFeed
                + 'WHERE wMiddle.ID IS NULL AND (w.wait_time_ms - wPrior.wait_time_ms) > 0;;'')'
            EXEC(@StringToExecute);
            END


        SET @StringToExecute = N' IF EXISTS(SELECT * FROM '
            + @OutputDatabaseName
            + '.INFORMATION_SCHEMA.SCHEMATA WHERE QUOTENAME(SCHEMA_NAME) = '''
            + @OutputSchemaName + ''') INSERT '
            + @OutputDatabaseName + '.'
            + @OutputSchemaName + '.'
            + @OutputTableNameWaitStats
            + ' (ServerName, CheckDate, wait_type, wait_time_ms, signal_wait_time_ms, waiting_tasks_count) SELECT '''
            + CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128))
            + ''', ''' + CONVERT(NVARCHAR(100), @StartSampleTime, 121) + ''', '
            + 'wait_type, wait_time_ms, signal_wait_time_ms, waiting_tasks_count FROM #WaitStats WHERE Pass = 2 AND wait_time_ms > 0 AND waiting_tasks_count > 0';
        EXEC(@StringToExecute);
    END
    ELSE IF (SUBSTRING(@OutputTableNameWaitStats, 2, 2) = '##')
    BEGIN
        SET @StringToExecute = N' IF (OBJECT_ID(''tempdb..'
            + @OutputTableNameWaitStats
            + ''') IS NULL) CREATE TABLE '
            + @OutputTableNameWaitStats
            + ' (ID INT IDENTITY(1,1) NOT NULL,
                ServerName NVARCHAR(128),
                CheckDate DATETIMEOFFSET,
                wait_type NVARCHAR(60),
                wait_time_ms BIGINT,
                signal_wait_time_ms BIGINT,
                waiting_tasks_count BIGINT ,
                CONSTRAINT [PK_' + CAST(NEWID() AS CHAR(36)) + '] PRIMARY KEY CLUSTERED (ID ASC));'
            + ' INSERT '
            + @OutputTableNameWaitStats
            + ' (ServerName, CheckDate, wait_type, wait_time_ms, signal_wait_time_ms, waiting_tasks_count) SELECT '''
            + CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128))
            + ''', ''' + CONVERT(NVARCHAR(100), @StartSampleTime, 121) + ''', '
            + 'wait_type, wait_time_ms, signal_wait_time_ms, waiting_tasks_count FROM #WaitStats WHERE Pass = 2 AND wait_time_ms > 0 AND waiting_tasks_count > 0';
        EXEC(@StringToExecute);
    END
    ELSE IF (SUBSTRING(@OutputTableNameWaitStats, 2, 1) = '#')
    BEGIN
        RAISERROR('Due to the nature of Dymamic SQL, only global (i.e. double pound (##)) temp tables are supported for @OutputTableName', 16, 0)
    END




    DECLARE @separator AS VARCHAR(1);
    IF @OutputType = 'RSV'
        SET @separator = CHAR(31);
    ELSE
        SET @separator = ',';

    IF @OutputType = 'COUNT' AND @SinceStartup = 0
    BEGIN
        SELECT  COUNT(*) AS Warnings
        FROM    #BlitzFirstResults
    END
    ELSE
        IF @OutputType = 'Opserver1' AND @SinceStartup = 0
        BEGIN

            SELECT  r.[Priority] ,
                    r.[FindingsGroup] ,
                    r.[Finding] ,
                    r.[URL] ,
                    r.[Details],
                    r.[HowToStopIt] ,
                    r.[CheckID] ,
                    r.[StartTime],
                    r.[LoginName],
                    r.[NTUserName],
                    r.[OriginalLoginName],
                    r.[ProgramName],
                    r.[HostName],
                    r.[DatabaseID],
                    r.[DatabaseName],
                    r.[OpenTransactionCount],
                    r.[QueryPlan],
                    r.[QueryText],
                    qsNow.plan_handle AS PlanHandle,
                    qsNow.sql_handle AS SqlHandle,
                    qsNow.statement_start_offset AS StatementStartOffset,
                    qsNow.statement_end_offset AS StatementEndOffset,
                    [Executions] = qsNow.execution_count - (COALESCE(qsFirst.execution_count, 0)),
                    [ExecutionsPercent] = CAST(100.0 * (qsNow.execution_count - (COALESCE(qsFirst.execution_count, 0))) / (qsTotal.execution_count - qsTotalFirst.execution_count) AS DECIMAL(6,2)),
                    [Duration] = qsNow.total_elapsed_time - (COALESCE(qsFirst.total_elapsed_time, 0)),
                    [DurationPercent] = CAST(100.0 * (qsNow.total_elapsed_time - (COALESCE(qsFirst.total_elapsed_time, 0))) / (qsTotal.total_elapsed_time - qsTotalFirst.total_elapsed_time) AS DECIMAL(6,2)),
                    [CPU] = qsNow.total_worker_time - (COALESCE(qsFirst.total_worker_time, 0)),
                    [CPUPercent] = CAST(100.0 * (qsNow.total_worker_time - (COALESCE(qsFirst.total_worker_time, 0))) / (qsTotal.total_worker_time - qsTotalFirst.total_worker_time) AS DECIMAL(6,2)),
                    [Reads] = qsNow.total_logical_reads - (COALESCE(qsFirst.total_logical_reads, 0)),
                    [ReadsPercent] = CAST(100.0 * (qsNow.total_logical_reads - (COALESCE(qsFirst.total_logical_reads, 0))) / (qsTotal.total_logical_reads - qsTotalFirst.total_logical_reads) AS DECIMAL(6,2)),
                    [PlanCreationTime] = CONVERT(NVARCHAR(100), qsNow.creation_time ,121),
                    [TotalExecutions] = qsNow.execution_count,
                    [TotalExecutionsPercent] = CAST(100.0 * qsNow.execution_count / qsTotal.execution_count AS DECIMAL(6,2)),
                    [TotalDuration] = qsNow.total_elapsed_time,
                    [TotalDurationPercent] = CAST(100.0 * qsNow.total_elapsed_time / qsTotal.total_elapsed_time AS DECIMAL(6,2)),
                    [TotalCPU] = qsNow.total_worker_time,
                    [TotalCPUPercent] = CAST(100.0 * qsNow.total_worker_time / qsTotal.total_worker_time AS DECIMAL(6,2)),
                    [TotalReads] = qsNow.total_logical_reads,
                    [TotalReadsPercent] = CAST(100.0 * qsNow.total_logical_reads / qsTotal.total_logical_reads AS DECIMAL(6,2)),
                    r.[DetailsInt]
            FROM    #BlitzFirstResults r
                LEFT OUTER JOIN #QueryStats qsTotal ON qsTotal.Pass = 0
                LEFT OUTER JOIN #QueryStats qsTotalFirst ON qsTotalFirst.Pass = -1
                LEFT OUTER JOIN #QueryStats qsNow ON r.QueryStatsNowID = qsNow.ID
                LEFT OUTER JOIN #QueryStats qsFirst ON r.QueryStatsFirstID = qsFirst.ID
            ORDER BY r.Priority ,
                    r.FindingsGroup ,
                    CASE
                        WHEN r.CheckID = 6 THEN DetailsInt
                        ELSE 0
                    END DESC,
                    r.Finding,
                    r.ID;
        END
        ELSE IF @OutputType IN ( 'CSV', 'RSV' ) AND @SinceStartup = 0
        BEGIN

            SELECT  Result = CAST([Priority] AS NVARCHAR(100))
                    + @separator + CAST(CheckID AS NVARCHAR(100))
                    + @separator + COALESCE([FindingsGroup],
                                            '(N/A)') + @separator
                    + COALESCE([Finding], '(N/A)') + @separator
                    + COALESCE(DatabaseName, '(N/A)') + @separator
                    + COALESCE([URL], '(N/A)') + @separator
                    + COALESCE([Details], '(N/A)')
            FROM    #BlitzFirstResults
            ORDER BY Priority ,
                    FindingsGroup ,
                    CASE
                        WHEN CheckID = 6 THEN DetailsInt
                        ELSE 0
                    END DESC,
                    Finding,
                    Details;
        END
        ELSE IF @ExpertMode = 0 AND @OutputXMLasNVARCHAR = 0 AND @SinceStartup = 0
        BEGIN
            SELECT  [Priority] ,
                    [FindingsGroup] ,
                    [Finding] ,
                    [URL] ,
                    CAST(@StockDetailsHeader + [Details] + @StockDetailsFooter AS XML) AS Details,
                    CAST(@StockWarningHeader + HowToStopIt + @StockWarningFooter AS XML) AS HowToStopIt,
                    [QueryText],
                    [QueryPlan]
            FROM    #BlitzFirstResults
            WHERE (@Seconds > 0 OR (Priority IN (0, 250, 251, 255))) /* For @Seconds = 0, filter out broken checks for now */
            ORDER BY Priority ,
                    FindingsGroup ,
                    CASE
                        WHEN CheckID = 6 THEN DetailsInt
                        ELSE 0
                    END DESC,
                    Finding,
                    ID;
        END
        ELSE IF @ExpertMode = 0 AND @OutputXMLasNVARCHAR = 1 AND @SinceStartup = 0
        BEGIN
            SELECT  [Priority] ,
                    [FindingsGroup] ,
                    [Finding] ,
                    [URL] ,
                    CAST(@StockDetailsHeader + [Details] + @StockDetailsFooter AS NVARCHAR(MAX)) AS Details,
                    CAST([HowToStopIt] AS NVARCHAR(MAX)) AS HowToStopIt,
                    CAST([QueryText] AS NVARCHAR(MAX)) AS QueryText,
                    CAST([QueryPlan] AS NVARCHAR(MAX)) AS QueryPlan
            FROM    #BlitzFirstResults
            WHERE (@Seconds > 0 OR (Priority IN (0, 250, 251, 255))) /* For @Seconds = 0, filter out broken checks for now */
            ORDER BY Priority ,
                    FindingsGroup ,
                    CASE
                        WHEN CheckID = 6 THEN DetailsInt
                        ELSE 0
                    END DESC,
                    Finding,
                    ID;
        END
        ELSE IF @ExpertMode = 1
        BEGIN
            IF @SinceStartup = 0
                SELECT  r.[Priority] ,
                        r.[FindingsGroup] ,
                        r.[Finding] ,
                        r.[URL] ,
                        CAST(@StockDetailsHeader + r.[Details] + @StockDetailsFooter AS XML) AS Details,
                        CAST(@StockWarningHeader + r.HowToStopIt + @StockWarningFooter AS XML) AS HowToStopIt,
                        r.[CheckID] ,
                        r.[StartTime],
                        r.[LoginName],
                        r.[NTUserName],
                        r.[OriginalLoginName],
                        r.[ProgramName],
                        r.[HostName],
                        r.[DatabaseID],
                        r.[DatabaseName],
                        r.[OpenTransactionCount],
                        r.[QueryPlan],
                        r.[QueryText],
                        qsNow.plan_handle AS PlanHandle,
                        qsNow.sql_handle AS SqlHandle,
                        qsNow.statement_start_offset AS StatementStartOffset,
                        qsNow.statement_end_offset AS StatementEndOffset,
                        [Executions] = qsNow.execution_count - (COALESCE(qsFirst.execution_count, 0)),
                        [ExecutionsPercent] = CAST(100.0 * (qsNow.execution_count - (COALESCE(qsFirst.execution_count, 0))) / (qsTotal.execution_count - qsTotalFirst.execution_count) AS DECIMAL(6,2)),
                        [Duration] = qsNow.total_elapsed_time - (COALESCE(qsFirst.total_elapsed_time, 0)),
                        [DurationPercent] = CAST(100.0 * (qsNow.total_elapsed_time - (COALESCE(qsFirst.total_elapsed_time, 0))) / (qsTotal.total_elapsed_time - qsTotalFirst.total_elapsed_time) AS DECIMAL(6,2)),
                        [CPU] = qsNow.total_worker_time - (COALESCE(qsFirst.total_worker_time, 0)),
                        [CPUPercent] = CAST(100.0 * (qsNow.total_worker_time - (COALESCE(qsFirst.total_worker_time, 0))) / (qsTotal.total_worker_time - qsTotalFirst.total_worker_time) AS DECIMAL(6,2)),
                        [Reads] = qsNow.total_logical_reads - (COALESCE(qsFirst.total_logical_reads, 0)),
                        [ReadsPercent] = CAST(100.0 * (qsNow.total_logical_reads - (COALESCE(qsFirst.total_logical_reads, 0))) / (qsTotal.total_logical_reads - qsTotalFirst.total_logical_reads) AS DECIMAL(6,2)),
                        [PlanCreationTime] = CONVERT(NVARCHAR(100), qsNow.creation_time ,121),
                        [TotalExecutions] = qsNow.execution_count,
                        [TotalExecutionsPercent] = CAST(100.0 * qsNow.execution_count / qsTotal.execution_count AS DECIMAL(6,2)),
                        [TotalDuration] = qsNow.total_elapsed_time,
                        [TotalDurationPercent] = CAST(100.0 * qsNow.total_elapsed_time / qsTotal.total_elapsed_time AS DECIMAL(6,2)),
                        [TotalCPU] = qsNow.total_worker_time,
                        [TotalCPUPercent] = CAST(100.0 * qsNow.total_worker_time / qsTotal.total_worker_time AS DECIMAL(6,2)),
                        [TotalReads] = qsNow.total_logical_reads,
                        [TotalReadsPercent] = CAST(100.0 * qsNow.total_logical_reads / qsTotal.total_logical_reads AS DECIMAL(6,2)),
                        r.[DetailsInt]
                FROM    #BlitzFirstResults r
                    LEFT OUTER JOIN #QueryStats qsTotal ON qsTotal.Pass = 0
                    LEFT OUTER JOIN #QueryStats qsTotalFirst ON qsTotalFirst.Pass = -1
                    LEFT OUTER JOIN #QueryStats qsNow ON r.QueryStatsNowID = qsNow.ID
                    LEFT OUTER JOIN #QueryStats qsFirst ON r.QueryStatsFirstID = qsFirst.ID
                WHERE (@Seconds > 0 OR (Priority IN (0, 250, 251, 255))) /* For @Seconds = 0, filter out broken checks for now */
                ORDER BY r.Priority ,
                        r.FindingsGroup ,
                        CASE
                            WHEN r.CheckID = 6 THEN DetailsInt
                            ELSE 0
                        END DESC,
                        r.Finding,
                        r.ID;

            -------------------------
            --What happened: #WaitStats
            -------------------------
            IF @Seconds = 0
                BEGIN
                /* Measure waits in hours */
                ;WITH max_batch AS (
                    SELECT MAX(SampleTime) AS SampleTime
                    FROM #WaitStats
                )
                SELECT
                    'WAIT STATS' AS Pattern,
                    b.SampleTime AS [Sample Ended],
                    CAST(DATEDIFF(mi,wd1.SampleTime, wd2.SampleTime) / 60.0 AS DECIMAL(18,1)) AS [Hours Sample],
                    wd1.wait_type,
					COALESCE(wcat.WaitCategory, 'Unknown') AS wait_category,
                    CAST(c.[Wait Time (Seconds)] / 60.0 / 60 AS DECIMAL(18,1)) AS [Wait Time (Hours)],
                    CAST((wd2.wait_time_ms - wd1.wait_time_ms) / 1000.0 / 60 / 60 / cores.cpu_count / DATEDIFF(ss, wd1.SampleTime, wd2.SampleTime) AS DECIMAL(18,1)) AS [Per Core Per Hour],
                    CAST(c.[Signal Wait Time (Seconds)] / 60.0 / 60 AS DECIMAL(18,1)) AS [Signal Wait Time (Hours)],
                    CASE WHEN c.[Wait Time (Seconds)] > 0
                     THEN CAST(100.*(c.[Signal Wait Time (Seconds)]/c.[Wait Time (Seconds)]) AS NUMERIC(4,1))
                    ELSE 0 END AS [Percent Signal Waits],
                    (wd2.waiting_tasks_count - wd1.waiting_tasks_count) AS [Number of Waits],
                    CASE WHEN (wd2.waiting_tasks_count - wd1.waiting_tasks_count) > 0
                    THEN
                        CAST((wd2.wait_time_ms-wd1.wait_time_ms)/
                            (1.0*(wd2.waiting_tasks_count - wd1.waiting_tasks_count)) AS NUMERIC(12,1))
                    ELSE 0 END AS [Avg ms Per Wait],
                    N'http://www.brentozar.com/sql/wait-stats/#' + wd1.wait_type AS URL
                FROM  max_batch b
                JOIN #WaitStats wd2 ON
                    wd2.SampleTime =b.SampleTime
                JOIN #WaitStats wd1 ON
                    wd1.wait_type=wd2.wait_type AND
                    wd2.SampleTime > wd1.SampleTime
                CROSS APPLY (SELECT SUM(1) AS cpu_count FROM sys.dm_os_schedulers WHERE status = 'VISIBLE ONLINE' AND is_online = 1) AS cores
                CROSS APPLY (SELECT
                    CAST((wd2.wait_time_ms-wd1.wait_time_ms)/1000. AS NUMERIC(12,1)) AS [Wait Time (Seconds)],
                    CAST((wd2.signal_wait_time_ms - wd1.signal_wait_time_ms)/1000. AS NUMERIC(12,1)) AS [Signal Wait Time (Seconds)]) AS c
				LEFT OUTER JOIN ##WaitCategories wcat ON wd1.wait_type = wcat.WaitType
                WHERE (wd2.waiting_tasks_count - wd1.waiting_tasks_count) > 0
                    AND wd2.wait_time_ms-wd1.wait_time_ms > 0
                ORDER BY [Wait Time (Seconds)] DESC;
                END
            ELSE
                BEGIN
                /* Measure waits in seconds */
                ;WITH max_batch AS (
                    SELECT MAX(SampleTime) AS SampleTime
                    FROM #WaitStats
                )
                SELECT
                    'WAIT STATS' AS Pattern,
                    b.SampleTime AS [Sample Ended],
                    DATEDIFF(ss,wd1.SampleTime, wd2.SampleTime) AS [Seconds Sample],
                    wd1.wait_type,
					COALESCE(wcat.WaitCategory, 'Unknown') AS wait_category,
                    c.[Wait Time (Seconds)],
                    CAST((wd2.wait_time_ms - wd1.wait_time_ms) / 1000.0 / cores.cpu_count / DATEDIFF(ss, wd1.SampleTime, wd2.SampleTime) AS DECIMAL(18,1)) AS [Per Core Per Second],
                    c.[Signal Wait Time (Seconds)],
                    CASE WHEN c.[Wait Time (Seconds)] > 0
                     THEN CAST(100.*(c.[Signal Wait Time (Seconds)]/c.[Wait Time (Seconds)]) AS NUMERIC(4,1))
                    ELSE 0 END AS [Percent Signal Waits],
                    (wd2.waiting_tasks_count - wd1.waiting_tasks_count) AS [Number of Waits],
                    CASE WHEN (wd2.waiting_tasks_count - wd1.waiting_tasks_count) > 0
                    THEN
                        CAST((wd2.wait_time_ms-wd1.wait_time_ms)/
                            (1.0*(wd2.waiting_tasks_count - wd1.waiting_tasks_count)) AS NUMERIC(12,1))
                    ELSE 0 END AS [Avg ms Per Wait],
                    N'http://www.brentozar.com/sql/wait-stats/#' + wd1.wait_type AS URL
                FROM  max_batch b
                JOIN #WaitStats wd2 ON
                    wd2.SampleTime =b.SampleTime
                JOIN #WaitStats wd1 ON
                    wd1.wait_type=wd2.wait_type AND
                    wd2.SampleTime > wd1.SampleTime
                CROSS APPLY (SELECT SUM(1) AS cpu_count FROM sys.dm_os_schedulers WHERE status = 'VISIBLE ONLINE' AND is_online = 1) AS cores
                CROSS APPLY (SELECT
                    CAST((wd2.wait_time_ms-wd1.wait_time_ms)/1000. AS NUMERIC(12,1)) AS [Wait Time (Seconds)],
                    CAST((wd2.signal_wait_time_ms - wd1.signal_wait_time_ms)/1000. AS NUMERIC(12,1)) AS [Signal Wait Time (Seconds)]) AS c
				LEFT OUTER JOIN ##WaitCategories wcat ON wd1.wait_type = wcat.WaitType
                WHERE (wd2.waiting_tasks_count - wd1.waiting_tasks_count) > 0
                    AND wd2.wait_time_ms-wd1.wait_time_ms > 0
                ORDER BY [Wait Time (Seconds)] DESC;
                END;

            -------------------------
            --What happened: #FileStats
            -------------------------
            WITH readstats AS (
                SELECT 'PHYSICAL READS' AS Pattern,
                ROW_NUMBER() OVER (ORDER BY wd2.avg_stall_read_ms DESC) AS StallRank,
                wd2.SampleTime AS [Sample Time],
                DATEDIFF(ss,wd1.SampleTime, wd2.SampleTime) AS [Sample (seconds)],
                wd1.DatabaseName ,
                wd1.FileLogicalName AS [File Name],
                UPPER(SUBSTRING(wd1.PhysicalName, 1, 2)) AS [Drive] ,
                wd1.SizeOnDiskMB ,
                ( wd2.num_of_reads - wd1.num_of_reads ) AS [# Reads/Writes],
                CASE WHEN wd2.num_of_reads - wd1.num_of_reads > 0
                  THEN CAST(( wd2.bytes_read - wd1.bytes_read)/1024./1024. AS NUMERIC(21,1))
                  ELSE 0
                END AS [MB Read/Written],
                wd2.avg_stall_read_ms AS [Avg Stall (ms)],
                wd1.PhysicalName AS [file physical name]
            FROM #FileStats wd2
                JOIN #FileStats wd1 ON wd2.SampleTime > wd1.SampleTime
                  AND wd1.DatabaseID = wd2.DatabaseID
                  AND wd1.FileID = wd2.FileID
            ),
            writestats AS (
                SELECT
                'PHYSICAL WRITES' AS Pattern,
                ROW_NUMBER() OVER (ORDER BY wd2.avg_stall_write_ms DESC) AS StallRank,
                wd2.SampleTime AS [Sample Time],
                DATEDIFF(ss,wd1.SampleTime, wd2.SampleTime) AS [Sample (seconds)],
                wd1.DatabaseName ,
                wd1.FileLogicalName AS [File Name],
                UPPER(SUBSTRING(wd1.PhysicalName, 1, 2)) AS [Drive] ,
                wd1.SizeOnDiskMB ,
                ( wd2.num_of_writes - wd1.num_of_writes ) AS [# Reads/Writes],
                CASE WHEN wd2.num_of_writes - wd1.num_of_writes > 0
                  THEN CAST(( wd2.bytes_written - wd1.bytes_written)/1024./1024. AS NUMERIC(21,1))
                  ELSE 0
                END AS [MB Read/Written],
                wd2.avg_stall_write_ms AS [Avg Stall (ms)],
                wd1.PhysicalName AS [file physical name]
            FROM #FileStats wd2
                JOIN #FileStats wd1 ON wd2.SampleTime > wd1.SampleTime
                  AND wd1.DatabaseID = wd2.DatabaseID
                  AND wd1.FileID = wd2.FileID
            )
            SELECT
                Pattern, [Sample Time], [Sample (seconds)], [File Name], [Drive],  [# Reads/Writes],[MB Read/Written],[Avg Stall (ms)], [file physical name]
            FROM readstats
            WHERE StallRank <=5 AND [MB Read/Written] > 0
            UNION ALL
            SELECT Pattern, [Sample Time], [Sample (seconds)], [File Name], [Drive],  [# Reads/Writes],[MB Read/Written],[Avg Stall (ms)], [file physical name]
            FROM writestats
            WHERE StallRank <=5 AND [MB Read/Written] > 0;


            -------------------------
            --What happened: #PerfmonStats
            -------------------------

            SELECT 'PERFMON' AS Pattern, pLast.[object_name], pLast.counter_name, pLast.instance_name,
                pFirst.SampleTime AS FirstSampleTime, pFirst.cntr_value AS FirstSampleValue,
                pLast.SampleTime AS LastSampleTime, pLast.cntr_value AS LastSampleValue,
                pLast.cntr_value - pFirst.cntr_value AS ValueDelta,
                ((1.0 * pLast.cntr_value - pFirst.cntr_value) / DATEDIFF(ss, pFirst.SampleTime, pLast.SampleTime)) AS ValuePerSecond
                FROM #PerfmonStats pLast
                    INNER JOIN #PerfmonStats pFirst ON pFirst.[object_name] = pLast.[object_name] AND pFirst.counter_name = pLast.counter_name AND (pFirst.instance_name = pLast.instance_name OR (pFirst.instance_name IS NULL AND pLast.instance_name IS NULL))
                    AND pLast.ID > pFirst.ID
				WHERE pLast.cntr_value <> pFirst.cntr_value
                ORDER BY Pattern, pLast.[object_name], pLast.counter_name, pLast.instance_name


            -------------------------
            --What happened: #QueryStats
            -------------------------
            IF @CheckProcedureCache = 1
			BEGIN
			
			SELECT qsNow.*, qsFirst.*
            FROM #QueryStats qsNow
              INNER JOIN #QueryStats qsFirst ON qsNow.[sql_handle] = qsFirst.[sql_handle] AND qsNow.statement_start_offset = qsFirst.statement_start_offset AND qsNow.statement_end_offset = qsFirst.statement_end_offset AND qsNow.plan_generation_num = qsFirst.plan_generation_num AND qsNow.plan_handle = qsFirst.plan_handle AND qsFirst.Pass = 1
            WHERE qsNow.Pass = 2
			END
			ELSE
			BEGIN
			SELECT 'Plan Cache' AS [Pattern], 'Plan cache not analyzed' AS [Finding], 'Use @CheckProcedureCache = 1 or run sp_BlitzCache for more analysis' AS [More Info], CONVERT(XML, @StockDetailsHeader + 'firstresponderkit.org' + @StockDetailsFooter) AS [Details]
			END
        END

    DROP TABLE #BlitzFirstResults;

    /* What's running right now? This is the first and last result set. */
    IF @SinceStartup = 0 AND @Seconds > 0 AND @ExpertMode = 1 
IF @SinceStartup = 0 AND @Seconds > 0 AND @ExpertMode = 1 
    BEGIN
		IF OBJECT_ID('master.dbo.sp_BlitzWho') IS NULL AND OBJECT_ID('dbo.sp_BlitzWho') IS NULL
		BEGIN
			PRINT N'sp_BlitzWho is not installed in the current database_files.  You can get a copy from http://FirstResponderKit.org'
		END
		ELSE
		BEGIN
			EXEC (@BlitzWho)
		END
    END /* IF @SinceStartup = 0 AND @Seconds > 0 AND @ExpertMode = 1   -   What's running right now? This is the first and last result set. */

END /* IF @Question IS NULL */
ELSE IF @Question IS NOT NULL

/* We're playing Magic SQL 8 Ball, so give them an answer. */
BEGIN
    IF OBJECT_ID('tempdb..#BlitzFirstAnswers') IS NOT NULL
        DROP TABLE #BlitzFirstAnswers;
    CREATE TABLE #BlitzFirstAnswers(Answer VARCHAR(200) NOT NULL);
    INSERT INTO #BlitzFirstAnswers VALUES ('It sounds like a SAN problem.');
    INSERT INTO #BlitzFirstAnswers VALUES ('You know what you need? Bacon.');
    INSERT INTO #BlitzFirstAnswers VALUES ('Talk to the developers about that.');
    INSERT INTO #BlitzFirstAnswers VALUES ('Let''s post that on StackOverflow.com and find out.');
    INSERT INTO #BlitzFirstAnswers VALUES ('Have you tried adding an index?');
    INSERT INTO #BlitzFirstAnswers VALUES ('Have you tried dropping an index?');
    INSERT INTO #BlitzFirstAnswers VALUES ('You can''t prove anything.');
    INSERT INTO #BlitzFirstAnswers VALUES ('Please phrase the question in the form of an answer.');
    INSERT INTO #BlitzFirstAnswers VALUES ('Outlook not so good. Access even worse.');
    INSERT INTO #BlitzFirstAnswers VALUES ('Did you try asking the rubber duck? http://www.codinghorror.com/blog/2012/03/rubber-duck-problem-solving.html');
    INSERT INTO #BlitzFirstAnswers VALUES ('Oooo, I read about that once.');
    INSERT INTO #BlitzFirstAnswers VALUES ('I feel your pain.');
    INSERT INTO #BlitzFirstAnswers VALUES ('http://LMGTFY.com');
    INSERT INTO #BlitzFirstAnswers VALUES ('No comprende Ingles, senor.');
    INSERT INTO #BlitzFirstAnswers VALUES ('I don''t have that problem on my Mac.');
    INSERT INTO #BlitzFirstAnswers VALUES ('Is Priority Boost on?');
    INSERT INTO #BlitzFirstAnswers VALUES ('Have you tried rebooting your machine?');
    INSERT INTO #BlitzFirstAnswers VALUES ('Try defragging your cursors.');
    INSERT INTO #BlitzFirstAnswers VALUES ('Why are you wearing that? Do you have a job interview later or something?');
    INSERT INTO #BlitzFirstAnswers VALUES ('I''m ashamed that you don''t know the answer to that question.');
    INSERT INTO #BlitzFirstAnswers VALUES ('Duh, Debra.');
    INSERT INTO #BlitzFirstAnswers VALUES ('Have you tried restoring TempDB?');
    SELECT TOP 1 Answer FROM #BlitzFirstAnswers ORDER BY NEWID();
END

END /* ELSE IF @OutputType = 'SCHEMA' */

SET NOCOUNT OFF;
GO



/* How to run it:
EXEC dbo.sp_BlitzFirst

With extra diagnostic info:
EXEC dbo.sp_BlitzFirst @ExpertMode = 1;

In Ask a Question mode:
EXEC dbo.sp_BlitzFirst 'Is this cursor bad?';

Saving output to tables:
EXEC sp_BlitzFirst @Seconds = 60
, @OutputDatabaseName = 'DBAtools'
, @OutputSchemaName = 'dbo'
, @OutputTableName = 'BlitzFirstResults'
, @OutputTableNameFileStats = 'BlitzFirstResults_FileStats'
, @OutputTableNamePerfmonStats = 'BlitzFirstResults_PerfmonStats'
, @OutputTableNameWaitStats = 'BlitzFirstResults_WaitStats'
*/
