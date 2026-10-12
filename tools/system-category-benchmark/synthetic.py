"""Deterministic English and Czech synthetic messages.

Each template renders several messages from slot values and [[a|b]] phrase choices. Templates,
not messages, are assigned to splits, so validation and test templates are never seen in training.
Synthetic behaviour checks are not real-world evidence; Czech has no real-public counterpart.
"""

import random
import re
import unicodedata

SEED = 828
RENDERINGS = 24
O, N, I, F, P = "Orders", "Newsletters & Promotions", "Invites", "Flights", "People"

SLOTS = {
    "en": {
        "first": [
            "Alice",
            "Ben",
            "Chloe",
            "Daniel",
            "Emma",
            "Farid",
            "Grace",
            "Hugo",
            "Isla",
            "Jonas",
        ],
        "last": ["Novak", "Walsh", "Okafor", "Brennan", "Lindqvist", "Moreau", "Patel", "Reyes"],
        "shop": [
            "Larkspur Home",
            "Blue Fern Books",
            "Copperline Outdoors",
            "Northgate Electronics",
            "Maple & Thread",
        ],
        "product": [
            "wireless headphones",
            "hiking boots",
            "a desk lamp",
            "two paperback novels",
            "a coffee grinder",
            "a rain jacket",
        ],
        "city": ["London", "Berlin", "Lisbon", "Chicago", "Toronto", "Madrid", "Oslo", "Dublin"],
        "airline": [
            "Skylark Airways",
            "Northwind Air",
            "Atlas Wings",
            "Bluebird Airlines",
            "Harbor Air",
        ],
        "event": [
            "the product roadmap review",
            "our quarterly planning session",
            "the design workshop",
            "the summer barbecue",
            "a retirement party",
        ],
        "place": [
            "the third-floor conference room",
            "Rosie's Cafe",
            "the rooftop terrace",
            "our Zoom room",
            "the community hall",
        ],
        "day": ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"],
        "time": ["9:30", "10:00", "12:30", "15:00", "16:45", "18:00"],
    },
    "cs": {
        "first": [
            "Jana",
            "Petr",
            "Lucie",
            "Tomáš",
            "Eva",
            "Martin",
            "Kateřina",
            "Jakub",
            "Tereza",
            "Ondřej",
        ],
        "last": [
            "Nováková",
            "Dvořák",
            "Svobodová",
            "Procházka",
            "Černá",
            "Kučera",
            "Veselá",
            "Horák",
        ],
        "shop": [
            "Zahrada Plus",
            "Knihkupectví Luna",
            "Elektro Domov",
            "Sportovna Kamzík",
            "Kávovar.cz",
        ],
        "product": [
            "bezdrátová sluchátka",
            "trekové boty",
            "stolní lampa",
            "dvě knihy",
            "mlýnek na kávu",
            "nepromokavá bunda",
        ],
        "city": ["Praha", "Brno", "Ostrava", "Vídeň", "Londýn", "Barcelona", "Paříž", "Řím"],
        "airline": ["Vltava Air", "Česká letecká", "Morava Wings", "Sněžka Airlines", "Šumava Air"],
        "event": [
            "porada k plánu produktu",
            "čtvrtletní plánování",
            "designový workshop",
            "letní grilovačka",
            "rozlučka se Zdeňkem",
        ],
        "place": [
            "zasedačka ve třetím patře",
            "kavárna U Rosy",
            "terasa na střeše",
            "naše místnost v Teams",
            "sokolovna",
        ],
        "day": ["v pondělí", "v úterý", "ve středu", "ve čtvrtek", "v pátek", "v sobotu"],
        "time": ["9:30", "10:00", "12:30", "15:00", "16:45", "18:00"],
    },
}

# (labels, sender, list headers, subject, body). Senders starting with "@" are automated
# addresses at a slot-filled domain; others are people. Group order decides splits.
TEMPLATES = {
    "en": {
        "orders": (
            [O],
            [
                (
                    "orders@{shop}",
                    False,
                    "Your {shop} order #{num} is confirmed",
                    "Thanks for your order! We've received order #{num} for {product}. Total charged: ${amount}. [[We'll email you when it ships.|You can track the status in your account.]]",
                ),
                (
                    "shipping@{shop}",
                    False,
                    "Your package is on its way",
                    "Good news: {product} from order #{num} has shipped and should arrive by {day}. Tracking number {code}. [[Delivery requires no signature.|Leave a safe place note in the app.]]",
                ),
                (
                    "billing@{shop}",
                    False,
                    "Invoice {code} for your account",
                    "Please find attached invoice {code} for ${amount}, due {day}. [[Payment will be taken automatically from your card.|Pay online from your billing page.]]",
                ),
                (
                    "receipts@{shop}",
                    False,
                    "Receipt for your payment of ${amount}",
                    "This is your receipt. We received ${amount} for {product} on {day}. Payment method: card ending {num4}.",
                ),
                (
                    "returns@{shop}",
                    False,
                    "Your refund has been processed",
                    "We've processed your return of {product}. A refund of ${amount} [[will appear on your statement within 5 days.|has been issued to your original payment method.]]",
                ),
                (
                    "billing@{shop}",
                    False,
                    "Action needed: payment failed",
                    "We couldn't charge your card for order #{num} (${amount}). Please update your payment details by {day} or the order will be cancelled.",
                ),
            ],
        ),
        "newsletters": (
            [N],
            [
                (
                    "news@{shop}",
                    True,
                    "This week at {shop}: {num} stories you missed",
                    "Welcome to our weekly newsletter. [[In this issue:|Inside:]] a guide to choosing {product}, interviews with our makers, and reader picks. Unsubscribe at any time.",
                ),
                (
                    "deals@{shop}",
                    True,
                    "{pct}% off everything this weekend only",
                    "Our biggest sale of the season is here! Use code {code} for {pct}% off sitewide, including {product}. [[Ends Sunday at midnight.|While stocks last.]]",
                ),
                (
                    "hello@{shop}",
                    True,
                    "Introducing our new collection",
                    "Meet the new range, featuring {product} redesigned from the ground up. Be the first to shop it and get free shipping on orders over $50.",
                ),
                (
                    "rewards@{shop}",
                    True,
                    "You have {num} points waiting",
                    "Your loyalty balance is {num} points. Redeem them for {product} or save toward your next reward. [[Points expire soon.|Members get double points this month.]]",
                ),
                (
                    "digest@{shop}",
                    True,
                    "Your monthly digest",
                    "Here are the most-read articles of the month, plus our editors' recommendations and upcoming releases. You are receiving this because you subscribed.",
                ),
                (
                    "offers@{shop}",
                    True,
                    "{first}, a gift just for you",
                    "As a valued customer you get a {pct}% coupon ({code}) on {product}. [[Shop now|Claim your gift]] before {day}.",
                ),
            ],
        ),
        "invites": (
            [I],
            [
                (
                    "calendar@{shop}",
                    False,
                    "Invitation: {event} @ {day} {time}",
                    "{first} {last} has invited you to {event} on {day} at {time} in {place}. [[Accept|Going?]] Yes / Maybe / No",
                ),
                (
                    "{first}",
                    False,
                    "Party at mine on {day}!",
                    "Hey! I'm having people over on {day} from {time}. It would be great if you could come. [[Let me know by Thursday so I know how much food to get.|RSVP when you can!]]",
                ),
                (
                    "{first}",
                    False,
                    "Save the date: our wedding",
                    "We're getting married! Please join us on {day} in {city}. Kindly RSVP by the end of the month so we can plan seating.",
                ),
                (
                    "{first}",
                    False,
                    "Team offsite - please confirm",
                    "Hi all, we're planning an offsite in {city} on {day}. Please reply by Friday to confirm whether you can attend.",
                ),
                (
                    "{first}",
                    False,
                    "Lunch {day}?",
                    "Would you like to join me for lunch on {day} at {time} at {place}? My treat this time.",
                ),
                (
                    "{first}",
                    False,
                    "Invitation to speak at our meetup",
                    "We'd love to have you speak at our next meetup in {city} on {day}. Could you let us know if you're available?",
                ),
            ],
        ),
        "flights": (
            [F],
            [
                (
                    "checkin@{airline}",
                    False,
                    "Check-in is now open for {flight} to {city}",
                    "Online check-in for flight {flight} to {city} on {day} is open. Departure {time}. Check in now to choose your seat.",
                ),
                (
                    "noreply@{airline}",
                    False,
                    "Your boarding pass",
                    "Your boarding pass for {flight}, {city} on {day}, is attached. Boarding starts at {time}, gate {gate}.",
                ),
                (
                    "alerts@{airline}",
                    False,
                    "Flight {flight} delayed",
                    "Flight {flight} to {city} is delayed. New departure time: {time}. [[We apologise for the inconvenience.|Please check the departures board.]]",
                ),
                (
                    "noreply@{airline}",
                    False,
                    "Schedule change for your trip to {city}",
                    "The departure time of {flight} on {day} has changed to {time}. No action is needed if the new time suits you.",
                ),
                (
                    "trips@{shop}",
                    False,
                    "Your itinerary: {city}",
                    "Here is your trip itinerary. Outbound: {airline} {flight}, {day} {time}. Seats confirmed. Have a great trip.",
                ),
                (
                    "noreply@{airline}",
                    False,
                    "Your seat upgrade is confirmed",
                    "Good news: you've been upgraded on {flight} to {city} on {day}. Your new seat is {gate}.",
                ),
            ],
        ),
        "people": (
            [P],
            [
                (
                    "{first}",
                    False,
                    "Quick question",
                    "Hi, do you still have the notes from last week? I can't find my copy. [[Thanks!|Cheers,]] {first}",
                ),
                (
                    "{first}",
                    False,
                    "Re: draft",
                    "Thanks for sending this over. I've added a few comments on section two; the rest looks good to me.",
                ),
                (
                    "{first}",
                    False,
                    "Photos from the weekend",
                    "Finally sorted through the photos from {city}! [[Mum loved the one by the river.|The kids look so grown up.]] Talk soon.",
                ),
                (
                    "{first}",
                    False,
                    "Can you review this?",
                    "Hey, when you have a minute could you look at my proposal before I send it to {first2}? No rush.",
                ),
                (
                    "{first}",
                    False,
                    "Re: Re: budget numbers",
                    "I think we should round up the travel estimate. Happy to discuss tomorrow if easier.",
                ),
                (
                    "{first}",
                    False,
                    "Book recommendation",
                    "You mentioned you wanted something new to read - I just finished a great novel set in {city}. I'll lend it to you.",
                ),
            ],
        ),
        "uncategorized": (
            [],
            [
                (
                    "security@{shop}",
                    False,
                    "Reset your password",
                    "We received a request to reset your password. Use code {code} within 15 minutes. If this wasn't you, ignore this email.",
                ),
                (
                    "alerts@{shop}",
                    False,
                    "New sign-in to your account",
                    "We noticed a new sign-in from {city} on {day}. If this was you, no action is needed.",
                ),
                (
                    "monitoring@{shop}",
                    False,
                    "[ALERT] Disk usage above 90% on db-{num}",
                    "Host db-{num} disk usage is at 93%. Triggered {day} {time}. This is an automated message.",
                ),
                (
                    "docs@{shop}",
                    False,
                    "{first} shared a document with you",
                    '{first} {last} shared "Q{num4} planning" with you. Open the document to view it.',
                ),
                (
                    "{first}",
                    True,
                    "Re: [users] build fails on ARM",
                    "I see the same error with version {num}. Setting the flag in the config fixed it for me. -- users mailing list",
                ),
                (
                    "announcements@{shop}",
                    False,
                    "Office closed on {day}",
                    "To all staff: the office will be closed on {day} for maintenance. Please work from home.",
                ),
            ],
        ),
        "overlap-orders-flights": (
            [O, F],
            [
                (
                    "bookings@{airline}",
                    False,
                    "Booking confirmation and e-ticket {code}",
                    "Thank you for booking with {airline}. Flight {flight} to {city} on {day} at {time}. Total paid ${amount}. Your e-ticket number is {code}.",
                ),
                (
                    "trips@{shop}",
                    False,
                    "Receipt: flight to {city}",
                    "Payment of ${amount} received for your flight {flight} on {day}. Your itinerary and receipt are attached.",
                ),
                (
                    "noreply@{airline}",
                    False,
                    "Your change fee receipt",
                    "We've changed your flight to {flight} on {day} and charged a fee of ${amount}. Updated itinerary below.",
                ),
            ],
        ),
        "overlap-invites-newsletters": (
            [I, N],
            [
                (
                    "events@{shop}",
                    True,
                    "You're invited: live webinar on {day}",
                    "Join our experts for a free webinar about {product} on {day} at {time}. Register now - seats are limited. Unsubscribe here.",
                ),
                (
                    "community@{shop}",
                    True,
                    "Join us for our store opening in {city}",
                    "Celebrate with us on {day}: drinks, live music and {pct}% off for guests. RSVP to reserve your spot.",
                ),
                (
                    "events@{shop}",
                    True,
                    "Last chance to register for the summit",
                    "Our annual summit is on {day} in {city}. Reply or register today to secure early-bird pricing.",
                ),
            ],
        ),
        "hard-not-people": (
            [N],
            [
                (
                    "sarah@{shop}",
                    True,
                    "Checking in",
                    "Hi {first}, it's Sarah from {shop}. Just wanted to see how you're getting on with {product}! [[Our customers also love the matching case.|Here's {pct}% off your next order.]]",
                ),
                (
                    "ceo@{shop}",
                    True,
                    "A personal note from our founder",
                    "Dear friend, I started {shop} in my kitchen. Thank you for being part of the journey. Enjoy {pct}% off with code {code}.",
                ),
                (
                    "deals@{airline}",
                    True,
                    "Fares to {city} from $99",
                    "Escape this season: return fares to {city} from $99 with {airline}. Book by {day}.",
                ),
            ],
        ),
        "hard-people": (
            [P],
            [
                (
                    "{first}",
                    False,
                    "Running late",
                    "My flight from {city} was delayed, so I'll be about an hour late. Can you start without me?",
                ),
                (
                    "{first}",
                    False,
                    "Re: the parcel",
                    "Did your order from {shop} ever arrive? Mine took ages. Anyway, see you {day}.",
                ),
                (
                    "{first}",
                    False,
                    "Re: meeting notes",
                    "Thanks for the notes from {event}. I agree with the second point; let's discuss when we next speak.",
                ),
            ],
        ),
    },
    "cs": {
        "orders": (
            [O],
            [
                (
                    "objednavky@{shop}",
                    False,
                    "Objednávka č. {num} byla přijata",
                    "Děkujeme za objednávku! Přijali jsme objednávku č. {num}: {product}. Celkem zaplaceno {amount} Kč. [[O odeslání vás budeme informovat.|Stav sledujte ve svém účtu.]]",
                ),
                (
                    "expedice@{shop}",
                    False,
                    "Vaše zásilka je na cestě",
                    "Objednávka č. {num} ({product}) byla odeslána a dorazí nejpozději {day}. Číslo zásilky {code}.",
                ),
                (
                    "fakturace@{shop}",
                    False,
                    "Faktura {code}",
                    "V příloze zasíláme fakturu {code} na částku {amount} Kč splatnou {day}. [[Platba proběhne automaticky.|Zaplatit můžete online.]]",
                ),
                (
                    "uctenky@{shop}",
                    False,
                    "Potvrzení platby {amount} Kč",
                    "Děkujeme, platba {amount} Kč za {product} byla přijata {day}. Platební karta končící {num4}.",
                ),
                (
                    "reklamace@{shop}",
                    False,
                    "Vrácení peněz bylo zpracováno",
                    "Zpracovali jsme vrácení zboží ({product}). Částka {amount} Kč [[bude připsána do 5 dnů.|byla vrácena na vaši kartu.]]",
                ),
                (
                    "fakturace@{shop}",
                    False,
                    "Platba se nezdařila",
                    "Nepodařilo se strhnout platbu za objednávku č. {num} ({amount} Kč). Aktualizujte prosím platební údaje nejpozději {day}, jinak objednávku zrušíme.",
                ),
            ],
        ),
        "newsletters": (
            [N],
            [
                (
                    "novinky@{shop}",
                    True,
                    "Týden v {shop}: {num} článků, které jste minuli",
                    "Vítejte u týdenního newsletteru. [[V tomto čísle:|Uvnitř najdete:]] průvodce výběrem ({product}), rozhovory a tipy čtenářů. Odhlásit se můžete kdykoli.",
                ),
                (
                    "akce@{shop}",
                    True,
                    "Sleva {pct} % na vše jen o víkendu",
                    "Největší výprodej sezóny je tady! S kódem {code} máte slevu {pct} % na celý sortiment. [[Platí do neděle.|Do vyprodání zásob.]]",
                ),
                (
                    "ahoj@{shop}",
                    True,
                    "Představujeme novou kolekci",
                    "Seznamte se s novinkami - {product} v úplně novém provedení. Nakupte mezi prvními s dopravou zdarma.",
                ),
                (
                    "vernost@{shop}",
                    True,
                    "Čeká na vás {num} bodů",
                    "Na věrnostním účtu máte {num} bodů. Vyměňte je za odměnu nebo je šetřete dál. [[Body brzy vyprší.|Tento měsíc dvojnásobné body.]]",
                ),
                (
                    "zpravodaj@{shop}",
                    True,
                    "Měsíční přehled",
                    "Nejčtenější články měsíce, doporučení redakce a chystané novinky. Tento e-mail dostáváte, protože jste se přihlásili k odběru.",
                ),
                (
                    "nabidky@{shop}",
                    True,
                    "Dárek jen pro vás",
                    "Jako věrný zákazník získáváte slevový kupón {code} ({pct} %) na {product}. [[Nakupte hned|Uplatněte dárek]] nejpozději {day}.",
                ),
            ],
        ),
        "invites": (
            [I],
            [
                (
                    "kalendar@{shop}",
                    False,
                    "Pozvánka: {event} – {day} {time}",
                    "{first} {last} vás zve na událost {event}, {day} v {time}, místo: {place}. [[Přijmout|Zúčastníte se?]] Ano / Možná / Ne",
                ),
                (
                    "{first}",
                    False,
                    "Mejdan u mě {day}!",
                    "Ahoj! Dělám u sebe {day} od {time} menší oslavu. Budu moc rád, když přijdeš. [[Dej mi vědět do čtvrtka.|Napiš, jestli dorazíš!]]",
                ),
                (
                    "{first}",
                    False,
                    "Svatba – uložte si datum",
                    "Bereme se! Oslava bude {day}, místo: {city}. Prosíme o potvrzení účasti do konce měsíce.",
                ),
                (
                    "{first}",
                    False,
                    "Teambuilding – potvrďte účast",
                    "Ahoj všichni, plánujeme {day} výjezd (místo: {city}). Do pátku prosím odpovězte, jestli pojedete.",
                ),
                (
                    "{first}",
                    False,
                    "Oběd {day}?",
                    "Nešel bys se mnou {day} v {time} na oběd? Místo: {place}. Tentokrát platím já.",
                ),
                (
                    "{first}",
                    False,
                    "Pozvání na přednášku",
                    "Rádi bychom vás pozvali jako řečníka na náš meetup ({city}, {day}). Dáte nám vědět, jestli máte čas?",
                ),
            ],
        ),
        "flights": (
            [F],
            [
                (
                    "checkin@{airline}",
                    False,
                    "Odbavení na let {flight} je otevřeno",
                    "Online odbavení na let {flight} do destinace {city} ({day}) je otevřeno. Odlet v {time}. Odbavte se a vyberte si sedadlo.",
                ),
                (
                    "noreply@{airline}",
                    False,
                    "Váš palubní lístek",
                    "V příloze najdete palubní lístek na let {flight}, {city}, {day}. Nástup začíná v {time}, gate {gate}.",
                ),
                (
                    "upozorneni@{airline}",
                    False,
                    "Let {flight} má zpoždění",
                    "Let {flight} do destinace {city} má zpoždění. Nový čas odletu: {time}. [[Omlouváme se za komplikace.|Sledujte odletovou tabuli.]]",
                ),
                (
                    "noreply@{airline}",
                    False,
                    "Změna letového řádu",
                    "Čas odletu letu {flight} ({day}) se změnil na {time}. Pokud vám nový čas vyhovuje, nemusíte nic dělat.",
                ),
                (
                    "cesty@{shop}",
                    False,
                    "Váš itinerář: {city}",
                    "Posíláme itinerář vaší cesty. Odlet: {airline} {flight}, {day} v {time}. Sedadla potvrzena. Šťastnou cestu.",
                ),
                (
                    "noreply@{airline}",
                    False,
                    "Upgrade sedadla potvrzen",
                    "Dobrá zpráva: na letu {flight} do destinace {city} ({day}) jste získali vyšší třídu. Nové sedadlo: {gate}.",
                ),
            ],
        ),
        "people": (
            [P],
            [
                (
                    "{first}",
                    False,
                    "Rychlý dotaz",
                    "Ahoj, nemáš ještě poznámky z minulého týdne? Nemůžu najít svoje. [[Díky!|Měj se,]] {first}",
                ),
                (
                    "{first}",
                    False,
                    "Re: koncept",
                    "Díky za poslání. Ke druhé části jsem připsal pár komentářů, zbytek mi přijde v pořádku.",
                ),
                (
                    "{first}",
                    False,
                    "Fotky z víkendu",
                    "Konečně jsem probral fotky z výletu ({city})! [[Mamce se líbila ta u řeky.|Děti už jsou tak velké.]] Ozvi se.",
                ),
                (
                    "{first}",
                    False,
                    "Mrkneš na to?",
                    "Ahoj, až budeš mít chvilku, mohl bys projít můj návrh, než ho pošlu dál? Nespěchá to.",
                ),
                (
                    "{first}",
                    False,
                    "Re: Re: rozpočet",
                    "Myslím, že bychom měli odhad cestovného zaokrouhlit nahoru. Klidně to probereme zítra.",
                ),
                (
                    "{first}",
                    False,
                    "Tip na knížku",
                    "Říkal jsi, že chceš něco nového ke čtení - zrovna jsem dočetl skvělý román. Půjčím ti ho.",
                ),
            ],
        ),
        "uncategorized": (
            [],
            [
                (
                    "bezpecnost@{shop}",
                    False,
                    "Obnovení hesla",
                    "Obdrželi jsme žádost o obnovení hesla. Použijte kód {code} do 15 minut. Pokud jste to nebyli vy, e-mail ignorujte.",
                ),
                (
                    "upozorneni@{shop}",
                    False,
                    "Nové přihlášení k účtu",
                    "Zaznamenali jsme nové přihlášení z místa {city} ({day}). Pokud jste to byli vy, nemusíte nic dělat.",
                ),
                (
                    "monitoring@{shop}",
                    False,
                    "[ALERT] Disk db-{num} zaplněn nad 90 %",
                    "Využití disku na serveru db-{num} je 93 %. Spuštěno {day} v {time}. Automatická zpráva.",
                ),
                (
                    "dokumenty@{shop}",
                    False,
                    "{first} s vámi sdílí dokument",
                    "{first} {last} s vámi sdílí dokument „Plán Q{num4}“. Otevřete jej pro zobrazení.",
                ),
                (
                    "{first}",
                    True,
                    "Re: [uzivatele] build padá na ARM",
                    "Stejnou chybu vidím ve verzi {num}. Pomohlo mi nastavit příznak v konfiguraci. -- konference uzivatele",
                ),
                (
                    "oznameni@{shop}",
                    False,
                    "Kancelář {day} zavřená",
                    "Všem zaměstnancům: kancelář bude {day} zavřená kvůli údržbě. Pracujte prosím z domova.",
                ),
            ],
        ),
        "overlap-orders-flights": (
            [O, F],
            [
                (
                    "rezervace@{airline}",
                    False,
                    "Potvrzení rezervace a e-ticket {code}",
                    "Děkujeme za rezervaci u {airline}. Let {flight} do destinace {city}, {day} v {time}. Zaplaceno {amount} Kč. Číslo e-ticketu {code}.",
                ),
                (
                    "cesty@{shop}",
                    False,
                    "Účtenka: let do destinace {city}",
                    "Přijali jsme platbu {amount} Kč za let {flight} ({day}). Itinerář a účtenku najdete v příloze.",
                ),
                (
                    "noreply@{airline}",
                    False,
                    "Potvrzení poplatku za změnu",
                    "Změnili jsme váš let na {flight} ({day}) a účtovali poplatek {amount} Kč. Aktualizovaný itinerář níže.",
                ),
            ],
        ),
        "overlap-invites-newsletters": (
            [I, N],
            [
                (
                    "akce@{shop}",
                    True,
                    "Zveme vás na webinář ({day})",
                    "Přidejte se k našim expertům na bezplatném webináři o tématu {product}, {day} v {time}. Registrujte se - počet míst je omezen. Odhlásit odběr.",
                ),
                (
                    "komunita@{shop}",
                    True,
                    "Přijďte na otevření prodejny ({city})",
                    "Oslavte to s námi {day}: drink, živá hudba a sleva {pct} % pro hosty. Potvrďte účast a zarezervujte si místo.",
                ),
                (
                    "akce@{shop}",
                    True,
                    "Poslední šance registrovat se na konferenci",
                    "Výroční konference proběhne {day}, místo: {city}. Zaregistrujte se ještě dnes za zvýhodněnou cenu.",
                ),
            ],
        ),
        "hard-not-people": (
            [N],
            [
                (
                    "sarka@{shop}",
                    True,
                    "Jak se vám daří?",
                    "Dobrý den, tady Šárka z {shop}. Jen jsem se chtěla zeptat, jak jste spokojeni ({product})! [[K tomu se hodí i obal.|Tady je sleva {pct} % na další nákup.]]",
                ),
                (
                    "zakladatel@{shop}",
                    True,
                    "Osobní slovo od zakladatele",
                    "Milí přátelé, {shop} jsem založil ve své kuchyni. Děkuji, že jste s námi. Užijte si slevu {pct} % s kódem {code}.",
                ),
                (
                    "akce@{airline}",
                    True,
                    "Letenky do destinace {city} od 1 990 Kč",
                    "Uleťte všednosti: zpáteční letenky do destinace {city} od 1 990 Kč s {airline}. Rezervujte nejpozději {day}.",
                ),
            ],
        ),
        "hard-people": (
            [P],
            [
                (
                    "{first}",
                    False,
                    "Mám zpoždění",
                    "Můj let z destinace {city} měl zpoždění, takže dorazím asi o hodinu později. Můžete začít beze mě?",
                ),
                (
                    "{first}",
                    False,
                    "Re: balík",
                    "Přišla ti nakonec ta objednávka z {shop}? Mně to trvalo věčnost. Tak se uvidíme {day}.",
                ),
                (
                    "{first}",
                    False,
                    "Re: zápis z porady",
                    "Díky za zápis z akce {event}. S druhým bodem souhlasím, probereme to příště.",
                ),
            ],
        ),
    },
}


SENDER_SLOTS = {"first", "last", "shop", "airline"}


def split_values(options: list[str], split: str) -> list[str]:
    # Every fifth value is held out, so no sender name or domain appears in two splits.
    kept = {"train": (0, 1, 2), "validation": (3,), "test": (4,)}[split]
    return [value for index, value in enumerate(options) if index % 5 in kept]


def template_split(template: str) -> str:
    group, index = template.rsplit("-", 1)
    count = len(TEMPLATES[group.split("-", 1)[0]][group.split("-", 1)[1]][1])
    position = int(index) - (count - 2)  # the last two templates of each group are held out
    return "train" if position < 0 else "validation" if position == 0 else "test"


def ascii_lower(text: str) -> str:
    return unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode().lower()


def domain(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", ascii_lower(name)) + ".example"


def render(text: str, values: dict, rng: random.Random) -> str:
    text = re.sub(r"\[\[(.+?)\]\]", lambda m: rng.choice(m.group(1).split("|")), text)
    return text.format(**values)


def generate() -> list[dict]:
    records = []
    for language, groups in TEMPLATES.items():
        for group, (labels, templates) in groups.items():
            for index, (sender, is_list, subject, body) in enumerate(templates):
                template = f"{language}-{group}-{index}"
                rng = random.Random(f"{SEED}:{template}")
                split = template_split(template)
                slots = {
                    key: split_values(options, split) if key in SENDER_SLOTS else options
                    for key, options in SLOTS[language].items()
                }
                seen = set()
                for n in range(RENDERINGS):
                    values = {key: rng.choice(options) for key, options in slots.items()}
                    values["first2"] = rng.choice(slots["first"])
                    values.update(
                        num=rng.randint(1000, 99999),
                        num4=rng.randint(1000, 9999),
                        amount=rng.choice([129, 349, 899, 1250, 2490, 4999])
                        if language == "cs"
                        else rng.choice(["12.99", "34.50", "89.00", "149.95", "420.00"]),
                        pct=rng.choice([10, 15, 20, 25, 30, 40, 50]),
                        code=f"{rng.choice('ABCDEFGHJK')}{rng.randint(100000, 999999)}",
                        flight=f"{rng.choice(['SK', 'NW', 'AW', 'BB', 'OK', 'VA'])}{rng.randint(100, 9999)}",
                        gate=f"{rng.choice('ABCD')}{rng.randint(1, 40)}",
                    )
                    if sender.startswith("{"):
                        first, last = values["first"], values["last"]
                        address = f"{first} {last} <{ascii_lower(first)}.{ascii_lower(last)}@mail.example>"
                    else:
                        local, org = sender.split("@")
                        org_name = values["airline"] if org == "{airline}" else values["shop"]
                        address = f"{org_name} <{local}@{domain(org_name)}>"
                    message = {
                        "subject": render(subject, values, rng),
                        "body": render(body, values, rng),
                    }
                    if (message["subject"], message["body"]) in seen:
                        continue
                    seen.add((message["subject"], message["body"]))
                    records.append(
                        {
                            "id": f"synthetic:{template}:{n}",
                            "source": "synthetic",
                            "stratum": "synthetic",
                            "language": language,
                            "template": template,
                            "from": address,
                            "reply_to": "",
                            "recipients": 250
                            if is_list or group == "uncategorized" and index == 5
                            else 1,
                            "list": is_list,
                            "date": "",
                            "labels": list(labels),
                            **message,
                        }
                    )
    return records
