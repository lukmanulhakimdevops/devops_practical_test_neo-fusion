-- SQL DDL for TodoItem table
CREATE TABLE TodoItems (
    Id INT PRIMARY KEY IDENTITY(1,1),
    Name NVARCHAR(255) NULL,
    IsComplete BIT NOT NULL
);