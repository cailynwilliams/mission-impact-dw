/*==============================================================
  MissionImpactDW - Patch: course code lookup
  Purpose: The Kaggle source uses anonymized course codes
           with no published program names.
           This adds a small reference table that maps
           each code to a readable program name and area, so
           reporting doesn't have to display raw codes.

           Names are illustrative for the fictional Mission
           Impact Foundation 

  Notes:   Creates the staging table. 
==============================================================*/

USE MissionImpactDW;
GO

/*--------------------------------------------------------------
  stg.course_lookup_raw
--------------------------------------------------------------*/
DROP TABLE IF EXISTS stg.course_lookup_raw;
GO

CREATE TABLE stg.course_lookup_raw (
    course_code       NVARCHAR(20)  NULL,
    program_name      NVARCHAR(200) NULL,
    program_area      NVARCHAR(100) NULL,
    src_file_name     NVARCHAR(260) NULL,
    load_batch_id     UNIQUEIDENTIFIER NULL,
    loaded_at_utc     DATETIME2(0)  NOT NULL
        CONSTRAINT DF_stg_course_lookup_loaded DEFAULT SYSUTCDATETIME()
);
GO


/*--------------------------------------------------------------
  Direct load.
--------------------------------------------------------------*/
TRUNCATE TABLE stg.course_lookup_raw;
GO

INSERT INTO stg.course_lookup_raw (course_code, program_name, program_area, src_file_name)
VALUES
    ('1',  'Executive Leadership Fellowship', 'Leadership',      'course_lookup.csv'),
    ('2',  'STEM Preparation',                 'STEM',             'course_lookup.csv'),
    ('3',  'Health Sciences Pathway',          'Health Sciences',  'course_lookup.csv'),
    ('4',  'Communications and Media',         'Arts',             'course_lookup.csv'),
    ('5',  'Environmental Studies',            'STEM',             'course_lookup.csv'),
    ('6',  'Business Administration',          'Business',         'course_lookup.csv'),
    ('7',  'Social Work Preparation',          'Human Services',   'course_lookup.csv'),
    ('8',  'Early Childhood Education',        'Education',        'course_lookup.csv'),
    ('9',  'Nursing Preparation',              'Health Sciences',  'course_lookup.csv'),
    ('10', 'Marketing and Design',             'Business',         'course_lookup.csv'),
    ('11', 'Public Health',                    'Health Sciences',  'course_lookup.csv'),
    ('12', 'College Access Foundations',       'General',          'course_lookup.csv'),
    ('13', 'Veterinary Sciences',              'Health Sciences',  'course_lookup.csv'),
    ('14', 'Information Technology',           'STEM',             'course_lookup.csv'),
    ('15', 'Hospitality and Tourism',          'Business',         'course_lookup.csv'),
    ('16', 'Journalism',                       'Arts',             'course_lookup.csv'),
    ('17', 'Human Services (Evening)',         'Human Services',   'course_lookup.csv');
GO


/*--------------------------------------------------------------
  Merge the readable names into dw.dim_program.

  Match on the current program_name column. 
--------------------------------------------------------------*/
MERGE dw.dim_program AS tgt
USING stg.course_lookup_raw AS src
ON tgt.program_name = src.course_code
WHEN MATCHED THEN
    UPDATE SET
        program_name  = src.program_name,
        program_area  = src.program_area
WHEN NOT MATCHED BY TARGET THEN
    INSERT (program_name, program_area)
    VALUES (src.program_name, src.program_area);
GO

PRINT 'Course lookup loaded and dim_program updated.';
GO

-- Verify
SELECT program_key, program_name, program_area
FROM dw.dim_program
WHERE program_key <> -1
ORDER BY program_name;
GO
