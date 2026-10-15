"""Synthetic English and Czech messages for Custom Category themes that corpus v2 lacks.

Corpus v2 holds work, tech-list and System Category mail but no school, bank, health or home
mail. Each theme has validation templates (the first half) and test templates (the second half)
per language and no training template, because Custom Category meanings are never trained.
Ambiguous-name themes pair each positive with a hard negative in both splits, such as a
nightclub promotion for "Club". Membership labels come from annotation, not themes.
"""

import random

import synthetic

RENDERINGS = 6
# Organization names per template, so no sender domain spans both splits; "" for people.
ORGS = {
    "kids-school": {
        "en": ("Oakridge Primary", "Hillside School"),
        "cs": ("ZŠ Na Výsluní", "ZŠ Komenského"),
    },
    "health-appointments": {
        "en": ("Riverside Clinic", "Elm Street Surgery"),
        "cs": ("Poliklinika Jih", "Ordinace Lipová"),
    },
    "bank-cards": {
        "en": ("Harbor Bank", "Northline Bank"),
        "cs": ("Banka Vltava", "Moravská banka"),
    },
    "statements": {
        "en": ("Crestview Bank", "Granite Holdings", "Northgate Card", "Pinecrest Group"),
        "cs": ("Banka Sever", "Holding Granit", "Karty Morava", "Skupina Borovice"),
    },
    "housing-rent": {
        "en": ("Parkside Lettings", "Willow Court Management"),
        "cs": ("Správa domů Praha", "Bytové družstvo Lípa"),
    },
    "utilities": {"en": ("Brightwater Energy", "FibreNet"), "cs": ("Energie Pro", "Optonet")},
    "insurance": {
        "en": ("Summit Insurance", "Shield Mutual"),
        "cs": ("Pojišťovna Lípa", "Jistota pojišťovna"),
    },
    "taxes": {
        "en": ("Revenue Service", "City Tax Office"),
        "cs": ("Finanční úřad Brno", "Finanční úřad Praha"),
    },
    "car-service": {
        "en": ("Ace Motors", "Quickfit Garage"),
        "cs": ("Autoservis Novák", "Pneu Expres"),
    },
    "job-search": {
        "en": ("Linden Logistics", "Corvid Software"),
        "cs": ("Logistika Linde", "Krkavec Software"),
    },
    "club-membership": {
        "en": ("", "Club Velvet", "Lakeside Tennis Club", "Club Neon"),
        "cs": ("", "Club Velvet", "Tenisový klub Jezero", "Club Neon"),
    },
    "sports-fitness": {
        "en": ("City Runners", "Metro 10K"),
        "cs": ("Běžci města", "Městská desítka"),
    },
    "volunteering-charity": {
        "en": ("Warm Meals Trust", "Green Parks Fund"),
        "cs": ("Teplé jídlo", "Zelené parky"),
    },
    "project-updates": {
        "en": ("", "Orbit Apps", "", "Desklight"),
        "cs": ("", "Orbit Apps", "", "Desklight"),
    },
}

# theme: (en templates, cs templates); each template is (sender, list headers, subject, body).
# Senders starting with "{first}" are people; others are automated addresses at the org's domain.
TEMPLATES = {
    "kids-school": (
        [
            (
                "office@{org}",
                False,
                "Year 3 trip to the science museum on {day}",
                "Dear parents, Year 3 will visit the science museum on {day}. Please return the consent form and pay the {amount} fee by Friday. Pupils need a packed lunch.",
            ),
            (
                "{first}",
                False,
                "Parent-teacher meeting",
                "Dear Mr and Mrs {last}, I would like to meet to discuss {first2}'s progress in maths this term. Would {day} at {time} work for you? Kind regards, {first}, class teacher",
            ),
        ],
        [
            (
                "kancelar@{org}",
                False,
                "Výlet 3. třídy do muzea {day}",
                "Vážení rodiče, třetí třída pojede {day} do technického muzea. Prosíme o podepsaný souhlas a úhradu {amount} Kč do pátku. Děti potřebují svačinu.",
            ),
            (
                "{first}",
                False,
                "Třídní schůzka",
                "Dobrý den, paní {last}, ráda bych s vámi probrala, jak se {first2} letos daří v matematice. Hodilo by se vám {day} v {time}? S pozdravem {first}, třídní učitelka",
            ),
        ],
    ),
    "health-appointments": (
        [
            (
                "appointments@{org}",
                False,
                "Appointment reminder: {day} at {time}",
                "This is a reminder of your appointment with Dr {last} on {day} at {time}. Please arrive 10 minutes early and bring your insurance card. Reply C to cancel.",
            ),
            (
                "results@{org}",
                False,
                "Your test results are ready",
                "Your blood test results from {day} are now available in the patient portal. Your doctor has added a note. Please do not reply to this message.",
            ),
        ],
        [
            (
                "objednavky@{org}",
                False,
                "Připomínka návštěvy: {day} v {time}",
                "Připomínáme vaši návštěvu u MUDr. {last} {day} v {time}. Přijďte prosím o 10 minut dříve a vezměte si kartičku pojištěnce. Pro zrušení odpovězte ZRUŠIT.",
            ),
            (
                "vysledky@{org}",
                False,
                "Výsledky vyšetření jsou k dispozici",
                "Výsledky krevních testů ze dne {day} najdete v pacientském portálu. Lékař k nim připsal poznámku. Na tuto zprávu prosím neodpovídejte.",
            ),
        ],
    ),
    "bank-cards": (
        [
            (
                "alerts@{org}",
                False,
                "Card payment of ${amount}",
                "Your debit card ending {num4} was used for a payment of ${amount} at {shop} on {day}. If you don't recognise this transaction, call us immediately.",
            ),
            (
                "cards@{org}",
                False,
                "Your new card is on its way",
                "Your replacement card ending {num4} has been sent and should arrive within 5 working days. Your old card will stop working once you activate the new one.",
            ),
        ],
        [
            (
                "upozorneni@{org}",
                False,
                "Platba kartou {amount} Kč",
                "Vaší debetní kartou končící {num4} byla {day} zaplacena částka {amount} Kč u obchodníka {shop}. Pokud transakci nepoznáváte, okamžitě nám zavolejte.",
            ),
            (
                "karty@{org}",
                False,
                "Nová karta je na cestě",
                "Náhradní karta končící {num4} byla odeslána a dorazí do 5 pracovních dnů. Stará karta přestane fungovat po aktivaci nové.",
            ),
        ],
    ),
    "statements": (
        [
            (
                "statements@{org}",
                False,
                "Your monthly statement is ready",
                "Your statement for the account ending {num4} is now available in online banking. Closing balance: ${amount}. Payments due by {day}.",
            ),
            (
                "press@{org}",
                True,
                "Statement from our CEO on the office move",
                "{org} confirms it will move its headquarters to {city} next year. The following statement may be quoted in full. Media enquiries: press office.",
            ),
            (
                "cards@{org}",
                False,
                "Your credit card statement",
                "Your credit card statement is available. New balance: ${amount}. The minimum payment is due on {day}. Log in to see all transactions.",
            ),
            (
                "ir@{org}",
                True,
                "Press statement on the quarterly results",
                "{org} today issued the following statement regarding its quarterly results and the planned merger. Media enquiries: press office.",
            ),
        ],
        [
            (
                "vypisy@{org}",
                False,
                "Měsíční výpis je připraven",
                "Výpis k účtu končícímu {num4} je k dispozici v internetovém bankovnictví. Konečný zůstatek: {amount} Kč. Splatnost {day}.",
            ),
            (
                "tisk@{org}",
                True,
                "Prohlášení generálního ředitele ke stěhování",
                "Společnost {org} potvrzuje, že příští rok přestěhuje sídlo do města {city}. Následující prohlášení lze citovat v plném znění. Dotazy médií: tiskové oddělení.",
            ),
            (
                "karty@{org}",
                False,
                "Výpis z kreditní karty",
                "Výpis z kreditní karty je k dispozici. Nový zůstatek: {amount} Kč. Minimální splátka je splatná {day}. Všechny transakce najdete po přihlášení.",
            ),
            (
                "tisk@{org}",
                True,
                "Tisková zpráva k čtvrtletním výsledkům",
                "Společnost {org} dnes vydala následující prohlášení ke čtvrtletním výsledkům a plánované fúzi. Dotazy médií: tiskové oddělení.",
            ),
        ],
    ),
    "housing-rent": (
        [
            (
                "{first}",
                False,
                "Boiler repair on {day}",
                "Hi, the plumber will come to fix the boiler in your flat on {day} between {time} and noon. Please make sure someone is home. Thanks, {first} (landlord)",
            ),
            (
                "management@{org}",
                False,
                "Residents' meeting and rent change",
                "Dear residents, the annual building meeting is on {day} at {time} in the lobby. From next quarter the monthly rent will rise by {pct}%.",
            ),
        ],
        [
            (
                "{first}",
                False,
                "Oprava kotle {day}",
                "Dobrý den, instalatér přijde opravit kotel ve vašem bytě {day} mezi {time} a polednem. Prosím, ať je někdo doma. Díky, {first} (pronajímatel)",
            ),
            (
                "sprava@{org}",
                False,
                "Schůze vlastníků a změna nájmu",
                "Vážení obyvatelé, výroční schůze domu bude {day} v {time} ve vstupní hale. Od příštího čtvrtletí se měsíční nájem zvýší o {pct} %.",
            ),
        ],
    ),
    "utilities": (
        [
            (
                "billing@{org}",
                False,
                "Your electricity bill for {day}",
                "Your electricity bill is ready: ${amount} for 312 kWh. The amount will be collected by direct debit on {day}. Compare your usage in the app.",
            ),
            (
                "service@{org}",
                False,
                "Planned internet outage in your area",
                "Due to network maintenance, your broadband service may be unavailable on {day} from {time} for up to two hours. We apologise for the inconvenience.",
            ),
        ],
        [
            (
                "vyuctovani@{org}",
                False,
                "Vyúčtování elektřiny",
                "Vyúčtování elektřiny je připraveno: {amount} Kč za 312 kWh. Částka bude stržena inkasem {day}. Porovnejte svou spotřebu v aplikaci.",
            ),
            (
                "servis@{org}",
                False,
                "Plánovaný výpadek internetu ve vaší oblasti",
                "Kvůli údržbě sítě může být vaše připojení {day} od {time} až dvě hodiny nedostupné. Omlouváme se za komplikace.",
            ),
        ],
    ),
    "insurance": (
        [
            (
                "policies@{org}",
                False,
                "Your car insurance renewal",
                "Your policy {code} renews on {day}. Your new annual premium is ${amount}. No action is needed if you want to keep the same cover.",
            ),
            (
                "claims@{org}",
                False,
                "Update on your claim {code}",
                "We have reviewed claim {code} for the water damage reported on {day}. An assessor will contact you to arrange a visit.",
            ),
        ],
        [
            (
                "smlouvy@{org}",
                False,
                "Prodloužení pojištění auta",
                "Vaše pojistka {code} se prodlužuje {day}. Nové roční pojistné činí {amount} Kč. Pokud chcete zachovat stejné krytí, nemusíte nic dělat.",
            ),
            (
                "udalosti@{org}",
                False,
                "Stav pojistné události {code}",
                "Posoudili jsme pojistnou událost {code} – škodu vodou nahlášenou {day}. Likvidátor se vám ozve kvůli prohlídce.",
            ),
        ],
    ),
    "taxes": (
        [
            (
                "{first}",
                False,
                "Documents for your tax return",
                "Hi, to finish your tax return I still need your mortgage interest certificate and the receipts for your donations. The deadline is {day}. Best, {first}",
            ),
            (
                "noreply@{org}",
                False,
                "Tax payment received",
                "We have received your income tax payment of ${amount} for reference {code}. Keep this confirmation for your records.",
            ),
        ],
        [
            (
                "{first}",
                False,
                "Podklady k daňovému přiznání",
                "Dobrý den, k dokončení přiznání ještě potřebuji potvrzení o úrocích z hypotéky a potvrzení o darech. Termín je {day}. S pozdravem {first}",
            ),
            (
                "noreply@{org}",
                False,
                "Přijetí platby daně",
                "Přijali jsme vaši platbu daně z příjmů {amount} Kč pod variabilním symbolem {code}. Toto potvrzení si uschovejte.",
            ),
        ],
    ),
    "car-service": (
        [
            (
                "service@{org}",
                False,
                "Your car is due for its annual service",
                "Our records show your car is due for its annual service and inspection. Book a slot online; the first available date is {day} at {time}.",
            ),
            (
                "{first}",
                False,
                "Re: winter tyres",
                "Your winter tyres are fitted and the brakes looked fine. You can pick the car up after {time}. The total is ${amount}. {first}, workshop",
            ),
        ],
        [
            (
                "servis@{org}",
                False,
                "Blíží se pravidelný servis vašeho vozu",
                "Podle našich záznamů se blíží pravidelná servisní prohlídka a STK vašeho vozu. Termín si rezervujte online; nejbližší volný je {day} v {time}.",
            ),
            (
                "{first}",
                False,
                "Re: zimní pneumatiky",
                "Zimní pneumatiky jsou přezuté a brzdy vypadaly v pořádku. Auto si můžete vyzvednout po {time}. Celkem {amount} Kč. {first}, dílna",
            ),
        ],
    ),
    "job-search": (
        [
            (
                "careers@{org}",
                False,
                "Interview invitation: Project Analyst",
                "Thank you for applying for the Project Analyst role. We would like to invite you to an interview on {day} at {time}. Please confirm your availability.",
            ),
            (
                "{first}",
                False,
                "CV for the open developer position",
                "Hi, attached is my CV for the developer position you advertised. I have five years of experience and could start next month. Best regards, {first} {last}",
            ),
        ],
        [
            (
                "kariera@{org}",
                False,
                "Pozvánka na pohovor: projektový analytik",
                "Děkujeme za zájem o pozici projektového analytika. Rádi bychom vás pozvali na pohovor {day} v {time}. Potvrďte prosím, zda vám termín vyhovuje.",
            ),
            (
                "{first}",
                False,
                "Životopis na pozici vývojáře",
                "Dobrý den, v příloze posílám životopis na inzerovanou pozici vývojáře. Mám pět let praxe a mohu nastoupit příští měsíc. S pozdravem {first} {last}",
            ),
        ],
    ),
    "club-membership": (
        [
            (
                "{first}",
                True,
                "Book club: next title and annual fee",
                "Hi everyone, our next book club evening is {day} at {time} at {place}. We are reading a novel set in {city}. Please pay this year's membership fee of ${amount}.",
            ),
            (
                "events@{org}",
                True,
                "Saturday at Club Velvet",
                "Guest DJ all night, free entry before {time} and half-price cocktails until midnight. Show this email at the door. Over 18s only.",
            ),
            (
                "committee@{org}",
                True,
                "Tennis club: court fees and spring league",
                "Dear members, the spring league starts {day}. Court fees for the season are ${amount}; please pay by the end of the month. Your club committee",
            ),
            (
                "events@{org}",
                True,
                "Friday night at Club Neon",
                "DJ sets until 4am, two-for-one cocktails before midnight and free entry before {time}. Show this email at the door. Over 18s only.",
            ),
        ],
        [
            (
                "{first}",
                True,
                "Čtenářský klub: další kniha a příspěvek",
                "Ahoj všichni, další setkání klubu bude {day} v {time}, místo: {place}. Čteme román z města {city}. Prosím o zaplacení letošního členského příspěvku {amount} Kč.",
            ),
            (
                "akce@{org}",
                True,
                "Sobota v Club Velvet",
                "Hostující DJ celou noc, vstup zdarma do {time} a koktejly za poloviční cenu do půlnoci. Ukažte tento e-mail u vchodu. Pouze 18+.",
            ),
            (
                "vybor@{org}",
                True,
                "Tenisový klub: poplatky za kurty a jarní liga",
                "Vážení členové, jarní liga začíná {day}. Poplatek za kurty na sezónu je {amount} Kč, uhraďte ho prosím do konce měsíce. Výbor klubu",
            ),
            (
                "akce@{org}",
                True,
                "Páteční noc v Club Neon",
                "DJ sety do 4 ráno, dva koktejly za cenu jednoho do půlnoci a vstup zdarma do {time}. Ukažte tento e-mail u vchodu. Pouze 18+.",
            ),
        ],
    ),
    "sports-fitness": (
        [
            (
                "{first}",
                False,
                "Saturday match lineup",
                "Hi team, we play away on {day}, kick-off {time}. Lineup is attached; bring both kits. Training on Thursday is cancelled. Coach {first}",
            ),
            (
                "hello@{org}",
                False,
                "Your race number for the city 10K",
                "You're registered for the city 10K on {day}. Your race number is {num}. Collect your timing chip at the start village before {time}.",
            ),
        ],
        [
            (
                "{first}",
                False,
                "Sestava na sobotní zápas",
                "Ahoj týme, v sobotu hrajeme venku, výkop {time}. Sestava je v příloze, vezměte si oba dresy. Čtvrteční trénink se ruší. Trenér {first}",
            ),
            (
                "ahoj@{org}",
                False,
                "Startovní číslo na městskou desítku",
                "Jste přihlášeni na městský běh na 10 km {day}. Vaše startovní číslo je {num}. Čip si vyzvedněte v zázemí startu do {time}.",
            ),
        ],
    ),
    "volunteering-charity": (
        [
            (
                "donate@{org}",
                True,
                "Your gift can feed a family this winter",
                "This winter, ${amount} provides warm meals for a family of four. Donate today and our partners will match your gift. Thank you for your support.",
            ),
            (
                "{first}",
                False,
                "Volunteers for the park clean-up",
                "Hi, we still need six volunteers for the park clean-up on {day} from {time}. Gloves and bags are provided. Can you help? {first}",
            ),
        ],
        [
            (
                "dary@{org}",
                True,
                "Váš dar nasytí rodinu touto zimou",
                "Touto zimou {amount} Kč zajistí teplá jídla pro čtyřčlennou rodinu. Darujte ještě dnes a naši partneři váš dar zdvojnásobí. Děkujeme za podporu.",
            ),
            (
                "{first}",
                False,
                "Dobrovolníci na úklid parku",
                "Ahoj, na úklid parku {day} od {time} ještě potřebujeme šest dobrovolníků. Rukavice a pytle zajistíme. Můžeš pomoct? {first}",
            ),
        ],
    ),
    "project-updates": (
        [
            (
                "{first}",
                False,
                "Status: warehouse migration",
                "Quick update on the warehouse migration: data transfer finished on {day}, testing is 80% done and we are still on track for go-live. Next step is user training. {first}",
            ),
            (
                "updates@{org}",
                True,
                "Firmware update for your router",
                "A new firmware version {num} is available for your router. It improves stability and fixes known issues. Install it from the settings page.",
            ),
            (
                "{first}",
                False,
                "Update: client onboarding",
                "Hi all, onboarding for the {city} client is complete: contracts are signed and the first delivery goes out {day}. Remaining risk is the data import. {first}",
            ),
            (
                "updates@{org}",
                True,
                "Software update available",
                "Version {num} of the desktop app is ready to install. It includes security fixes and performance improvements. Restart the app to update.",
            ),
        ],
        [
            (
                "{first}",
                False,
                "Stav: migrace skladu",
                "Krátce ke stavu migrace skladu: přenos dat skončil {day}, testování je hotové z 80 % a termín spuštění držíme. Dalším krokem je školení uživatelů. {first}",
            ),
            (
                "aktualizace@{org}",
                True,
                "Aktualizace firmwaru routeru",
                "Pro váš router je k dispozici nový firmware verze {num}. Zlepšuje stabilitu a opravuje známé chyby. Nainstalujte ho v nastavení.",
            ),
            (
                "{first}",
                False,
                "Novinky: spuštění klienta",
                "Ahoj všem, náběh klienta z města {city} je hotový: smlouvy jsou podepsané a první dodávka odchází {day}. Zbývajícím rizikem je import dat. {first}",
            ),
            (
                "aktualizace@{org}",
                True,
                "K dispozici je aktualizace softwaru",
                "Verze {num} desktopové aplikace je připravena k instalaci. Obsahuje bezpečnostní opravy a zlepšení výkonu. Pro aktualizaci aplikaci restartujte.",
            ),
        ],
    ),
}


def generate() -> list[dict]:
    """Render validation (first half) and test (second half) templates; no training split."""
    records = []
    for theme, by_language in TEMPLATES.items():
        for language, templates in zip(("en", "cs"), by_language):
            for index, (sender, is_list, subject, body) in enumerate(templates):
                split = "validation" if index < len(templates) // 2 else "test"
                template = f"custom-{language}-{theme}-{index}"
                rng = random.Random(f"{synthetic.SEED}:{template}")
                slots = {
                    key: synthetic.split_values(options, split)
                    if key in synthetic.SENDER_SLOTS
                    else options
                    for key, options in synthetic.SLOTS[language].items()
                }
                seen = set()
                for n in range(RENDERINGS):
                    values = {key: rng.choice(options) for key, options in slots.items()}
                    values.update(
                        first2=rng.choice(slots["first"]),
                        org=ORGS[theme][language][index],
                        num=rng.randint(1000, 99999),
                        num4=rng.randint(1000, 9999),
                        amount=rng.choice([129, 349, 899, 1250, 2490, 4999])
                        if language == "cs"
                        else rng.choice(["12.99", "34.50", "89.00", "149.95", "420.00"]),
                        pct=rng.choice([3, 5, 8, 10]),
                        code=f"{rng.choice('ABCDEFGHJK')}{rng.randint(100000, 999999)}",
                    )
                    if sender.startswith("{"):
                        first, last = values["first"], values["last"]
                        address = (
                            f"{first} {last} <{synthetic.ascii_lower(first)}."
                            f"{synthetic.ascii_lower(last)}@mail.example>"
                        )
                    else:
                        local = sender.split("@")[0]
                        address = f"{values['org']} <{local}@{synthetic.domain(values['org'])}>"
                    message = {
                        "subject": synthetic.render(subject, values, rng),
                        "body": synthetic.render(body, values, rng),
                    }
                    if (message["subject"], message["body"]) in seen:
                        continue
                    seen.add((message["subject"], message["body"]))
                    records.append(
                        {
                            "id": f"synthetic:{template}:{n}",
                            "source": "synthetic",
                            "stratum": "custom-synthetic",
                            "language": language,
                            "template": template,
                            "split": split,
                            "from": address,
                            "reply_to": "",
                            "recipients": 250 if is_list else 1,
                            "list": is_list,
                            "date": "",
                            "labels": [],
                            **message,
                        }
                    )
    return records
