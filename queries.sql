use Luxsoft
go

-- ############### CONSTRAINT
-- 1. sprawdza czy email jest poprawny
ALTER TABLE Pracownik
ADDCONSTRAINT ch_sprawdz_email CHECK (Email like '%[@]%')

-- 2. sprawdza czy jest do ZgloszeniaAwarii jest przydzielone jedno ZamowienieLicencji lub jedno ZamowienieSprzetu
ALTER TABLE ZgloszenieAwarii
ADDCONSTRAINT ch_czy_przypisano_produkt CHECK ((ZamowienieSprzetuID is NULL and ZamowienieLicencjiID is not NULL)
											or (ZamowienieSprzetuID is not NULL and ZamowienieLicencjiID is NULL))

-- 3. sprawdz czy data nowego statusu danego zgloszenia jest pozniejsza niz ostatnia dostepna juz w bazie
ALTER TABLE HistoriaZgloszenia with nocheck
ADDCONSTRAINT ch_daty_rosnaco CHECK (Data >= dbo.fn_maxDataHistZgl(ZgloszenieAwariiID))
GO
-- funkcja zwracajaca maksymalna date z historii dla danego zgloszenia
-- (poniewaz nie mozna umieszczac subquery bezposrednio w CHECK CONSTRAINT)
CREATE FUNCTION dbo.fn_maxDataHistZgl
	(@ido int)
	RETURNS date
BEGIN
	RETURN (select max(hz.Data) from HistoriaZgloszenia as hz where hz.ZgloszenieAwariiID = @ido)
END
GO

-- ############### VIEWS
-- 1. pokaz raport pracownikow w poszczegolnych Departamentach
CREATE VIEW v_RaportPracownikow
AS
	select
	p.Imie,
	p.Nazwisko,
	Czy_zatrudniony = CASE
						WHEN p.CzyZatrudniony = 1 THEN 'Tak'
						WHEN p.CzyZatrudniony = 0 THEN 'Nie'
						END,
	d.Nazwa as Departament,
	s.Nazwa as Stanowisko
	from Departament as d
	left outer join Pracownik as p on d.DepartamentID = p.DepartamentID
	left outer join Stanowisko as s on p.StanowiskoID = s.StanowiskoID
GO

-- 2. pokaz raport zgloszen awarii wraz z najswiezszym statusem i komentarzem
CREATE VIEW v_RaportAwarii
AS
	select
	za.ZgloszenieAwariiID,
	Przydzielony_Pracownik_Helpdesk = p.Imie + ' ' + p.Nazwisko,
	Produkt =
		CASE
			WHEN za.ZamowienieSprzetuID IS NOT NULL THEN 
				(select ms.Producent + ' ' + ms.Nazwa from ZamowienieSprzetu as zs
				inner join ModelSprzetu as ms on ms.ModelSprzetuID = zs.ModelSprzetuID
				where za.ZamowienieSprzetuID = zs.ZamowienieSprzetuID)
			WHEN za.ZamowienieLicencjiID IS NOT NULL THEN
				(select a.Producent + ' ' + a.Nazwa + ' ' +a.Wersja from ZamowienieLicencji as zl
				inner join Licencja as l on l.LicencjaID = zl.LicencjaID
				inner join Aplikacja as a on a.AplikacjaID = l.AplikacjaID
				where za.ZamowienieLicencjiID = zl.ZamowienieLicencjiID)		
		END,
	za.OpisProblemu,
	Priorytet = pa.Nazwa,
	Data_Zmiany_Stanu = (select max(hz.Data) from HistoriaZgloszenia as hz
						where hz.ZgloszenieAwariiID = za.ZgloszenieAwariiID),
	Stan = (select top 1 s.Nazwa from HistoriaZgloszenia as hz
			inner join Stan as s on s.StanID = hz.StanID
			where za.ZgloszenieAwariiID = hz.ZgloszenieAwariiID
			order by hz.Data desc),
	Komentarz = (select hz.Komentarz from HistoriaZgloszenia as hz
				where hz.Data = 
					(select max(hz.Data) from HistoriaZgloszenia as hz
					where hz.ZgloszenieAwariiID = za.ZgloszenieAwariiID) and hz.ZgloszenieAwariiID = za.ZgloszenieAwariiID)
	from ZgloszenieAwarii as za
	inner join Pracownik as p on p.PracownikID = za.PracownikHelpdeskID
	inner join PriorytetAwarii as pa on pa.PriorytetAwariiID = za.PriorytetAwariiID
GO

-- 3. pokaz licencje Zakupione (uzytkowane i nieuzytkowane, ale bez wycofanych) wraz z informacja o pozostalym okresie waznosci
CREATE VIEW v_ZestawienieLicencji
AS
	select
	zl.ZamowienieLicencjiID,
	ka.Nazwa as Kategoria,
	a.Producent + ' ' + a.Nazwa + ' ' + a.Wersja as Produkt,
	s.Nazwa as Stan,
	(select dbo.fn_PozostalyCzasLicencji(zl.DataZakupuLicencji,l.OkresWaznosci)) as Pozostalo_dni_licencji
	from ZamowienieLicencji as zl
	inner join Stan as s on s.StanID = zl.StanID
	inner join Licencja as l on l.LicencjaID = zl.LicencjaID
	inner join Aplikacja as a on a.AplikacjaID = l.AplikacjaID
	inner join RodzajLicencji as rl on rl.RodzajLicencjiID = l.RodzajLicencjiID
	inner join KategoriaAplikacji as ka on ka.KategoriaAplikacjiID = a.KategoriaAplikacjiID
	where zl.DataZakupuLicencji is not NULL and s.Nazwa <> 'Wycofano'
GO

-- funkcja obliczajaca pozostaly czas licencji
CREATE FUNCTION dbo.fn_PozostalyCzasLicencji
	(@data_zakupu date,
	@okres_dni int)
	RETURNS nvarchar(50)
BEGIN
	RETURN CASE
		WHEN @okres_dni = 0 THEN 'Licencja bezterminowa'
		WHEN @okres_dni - DATEDIFF(day,@data_zakupu,GETDATE()) < 0 THEN 'Licencja przeterminowana!'
		ELSE CONVERT(varchar(50),@okres_dni - DATEDIFF(day,@data_zakupu,GETDATE()))
	END
END
GO

-- ############### TRIGER
-- 1. zaktualizuj date zmiany hasla przy zmianie hasla
CREATE TRIGGER tr_DataZmianyHasla
	ON dbo.PracownikKonto
	FOR UPDATE
AS
BEGIN
	IF (select Haslo from inserted) <> (select Haslo from deleted)
		BEGIN
			update dbo.PracownikKonto set DataZmianyHasla = GETDATE()
			where PracownikKontoID = (select PracownikKontoID from inserted)
		END
END
GO

-- 2. przypisz nowa awarie do Analityka IT lub Administratora, ktory ma najmniej przypisanych awarii.
--		Analityk IT/Administrator nie moze obslugiwac sam siebie
CREATE TRIGGER tr_Przypisz_Analityka
	ON dbo.ZgloszenieAwarii
	FOR INSERT
AS
BEGIN
	select top 2 p.PracownikID as PracownikHelpdeskID, count(za.ZgloszenieAwariiID) as Ilosc into #pracowikRow
	from Pracownik as p
	inner join PracownikRola as pr on pr.PracownikKontoID = p.PracownikKontoID
	left outer join ZgloszenieAwarii as za on p.PracownikID = za.PracownikHelpdeskID
	join Rola as r on pr.RolaID = r.RolaID
	where r.Nazwa = 'Analityk IT' or r.Nazwa = 'Administrator'
	group by p.PracownikID
	order by Ilosc

	declare @pracownikIT int
	select @pracownikIT = PracownikHelpdeskID from #pracowikRow
	where PracownikHelpdeskID <> (select PracownikID from inserted)

	update dbo.ZgloszenieAwarii set PracownikHelpdeskID = @pracownikIT
	where ZgloszenieAwariiID = (select ZgloszenieAwariiID from inserted)
END
GO

-- ############### STORED PROCEDURE
-- 3. sprawdza czy podany login i haslo sa zgodne z tymi przechowywanymi w bazie
CREATE PROCEDURE sp_zaloguj
	@login varchar(20),
	@haslo varchar(20)
AS
BEGIN
	-- declare @status int
	IF @haslo = (select Haslo from PracownikKonto where Login = @login)
		BEGIN
			update PracownikKonto set DataOstatniegoLogowania = GETDATE() where Login = @login
			print 'Logowanie poprawne'
			-- select @status = 1
			return 1
		END
	ELSE
		BEGIN
			print 'Logowanie nie powiodlo sie'
			-- select @status = 0
			return 0
		END
END
GO
-- wywolanie
declare @status int
EXEC @status = sp_zaloguj 'grzegorz.kapera', 12345
select @status

-- ############### TRANSACTION
-- 1. transakcja wpisania ZamowieniaSprzetu dla nieistniejacego jeszcze w systemie Modelu
--		(Model zostanie dodany do bazy przy okazji zglaszania Zamowienia)
BEGIN TRANSACTION
	begin try
		insert ModelSprzetu (DystrybutorID, KategoriaModelSprzetuID, OkresGwarancji, Producent, Nazwa, Kwota, Waluta)
					values (1,1,200,'Lenovo', 'Ideapad 1300', 2000, 'PLN')
		
		declare @msID int
		select @msID=(select max(ModelSprzetuID) from ModelSprzetu)

		insert ParametrTechnicznySprzet (ModelSprzetuID, ParametrTechnicznyID, Wartosc)
					values (@msID, (select ParametrTechnicznyID from ParametrTechniczny where Nazwa = 'Pamiec RAM'), 2000),
							(@msID, (select ParametrTechnicznyID from ParametrTechniczny where Nazwa = 'Taktowanie procesora'), 2.1)

		insert ZamowienieSprzetu (ModelSprzetuID, StanID, DataZmianyStatusu, DataZakupuSprzetu, NumerSeryjny)
					values (@msID, (select StanID from Stan where Nazwa = 'W uzytkowaniu'),GETDATE(),GETDATE(),'LNV-12369')

		COMMIT TRANSACTION
	end try
	begin catch
		IF @@TRANCOUNT > 0
			ROLLBACK TRANSACTION
		select ERROR_NUMBER(),ERROR_MESSAGE(), ERROR_PROCEDURE(), ERROR_LINE()
	end catch
GO

-- 2. Stworz nowego uzytkownika (Transakcja + Procedura skladowana)
CREATE PROCEDURE sp_dodajSzeregowegoPracownika
	@imie varchar(50),
	@nazwisko varchar(50),
	@haslo varchar(20),
	@departament varchar(80),
	@stanowisko varchar(50)
AS
BEGIN
	BEGIN TRANSACTION
	begin try
		insert into PracownikKonto (Login,Haslo,DataUtworzeniaKonta,CzyZablokowane)
			values (left(@imie,9)+'.'+left(@nazwisko,10),@haslo,GETDATE(),0)
		
		declare @pkID int
		select @pkID=(select max(PracownikKontoID) from PracownikKonto)

		insert PracownikRola (PracownikKontoID,RolaID)
			values (@pkID,(select RolaID from Rola where Nazwa = 'Pracownik szeregowy'))

		insert Pracownik (PracownikKontoID, DepartamentID,
						StanowiskoID, Imie, Nazwisko, Email, CzyZatrudniony)
			values (@pkID, (select DepartamentID from Departament where Nazwa = @departament),
						(select StanowiskoID from Stanowisko where Nazwa = @stanowisko),
						@imie, @nazwisko,(select Login+'@firma.com' from PracownikKonto where PracownikKontoID = @pkID),1)
	
		COMMIT TRANSACTION
		print 'Uzytkownik poprawnie zarejestrowany'
	end try
	begin catch
		IF @@TRANCOUNT > 0
			ROLLBACK TRANSACTION
		print 'Nie udalo sie dodac uzytkownika'
		select ERROR_NUMBER(),ERROR_MESSAGE(), ERROR_PROCEDURE(), ERROR_LINE()
	end catch
END
GO
-- wywolanie
EXEC sp_dodajSzeregowegoPracownika Jaroslaw, Witek, 1234, Ksiegowosc, 'Glowny Ksiegowy'
