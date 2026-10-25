#!/usr/bin/env python3
"""Generate the French encryption declaration approval form for CribWire.

Output: docs/appstore/CribWire-French-Encryption-Declaration.pdf

The PDF is a fill-in-and-sign form. It is prepared from the app's own
documentation (docs/specs/security.md) so that the cryptography section is
accurate; the declarant identity, dates and the ANSSI reference are left blank
because only the publisher can supply them.

Usage:  python3 docs/appstore/build-french-encryption-declaration.py
"""

from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.enums import TA_JUSTIFY
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.platypus import (
    BaseDocTemplate,
    Frame,
    KeepTogether,
    PageTemplate,
    Paragraph,
    Spacer,
    Table,
    TableStyle,
)

OUT = Path(__file__).with_name("CribWire-French-Encryption-Declaration.pdf")

APP_NAME = "CribWire"
BUNDLE_ID = "com.ralphhees.cribwire.CribWire"
APPLE_TEAM_ID = "NRV7K64R87"
APP_VERSION = "0.1.0"

NAVY = colors.HexColor("#1B3A5C")
INK = colors.HexColor("#1A1A1A")
MUTED = colors.HexColor("#5A6672")
RULE = colors.HexColor("#B7C2CC")
BOXBG = colors.HexColor("#F2F5F8")
HEADBG = colors.HexColor("#E4EAF0")

PAGE_W, PAGE_H = A4
MARGIN = 18 * mm
CONTENT_W = PAGE_W - 2 * MARGIN

_ss = getSampleStyleSheet()


def style(name, **kw):
    base = kw.pop("parent", _ss["BodyText"])
    return ParagraphStyle(name, parent=base, **kw)


S = {
    "title": style("title", fontName="Helvetica-Bold", fontSize=17, leading=21,
                   textColor=NAVY, spaceAfter=2),
    "subtitle": style("subtitle", fontName="Helvetica", fontSize=11.5, leading=15,
                      textColor=MUTED, spaceAfter=10),
    "h2": style("h2", fontName="Helvetica-Bold", fontSize=10.5, leading=13,
                textColor=colors.white, spaceAfter=0),
    "h3": style("h3", fontName="Helvetica-Bold", fontSize=9.5, leading=12,
                textColor=NAVY, spaceBefore=6, spaceAfter=3),
    "body": style("body", fontName="Helvetica", fontSize=8.8, leading=12,
                  textColor=INK, alignment=TA_JUSTIFY, spaceAfter=5),
    "en": style("en", fontName="Helvetica-Oblique", fontSize=8, leading=11,
                textColor=MUTED, alignment=TA_JUSTIFY, spaceAfter=5),
    "label": style("label", fontName="Helvetica-Bold", fontSize=8.2, leading=10.5,
                   textColor=INK, spaceAfter=0),
    "labelen": style("labelen", fontName="Helvetica-Oblique", fontSize=7, leading=9,
                     textColor=MUTED, spaceAfter=0),
    "fill": style("fill", fontName="Helvetica", fontSize=8.5, leading=11,
                  textColor=INK, spaceAfter=0),
    "cell": style("cell", fontName="Helvetica", fontSize=7.6, leading=9.6,
                  textColor=INK, spaceAfter=0),
    "cellb": style("cellb", fontName="Helvetica-Bold", fontSize=7.6, leading=9.6,
                   textColor=INK, spaceAfter=0),
    "cellhead": style("cellhead", fontName="Helvetica-Bold", fontSize=7.6, leading=9.6,
                      textColor=NAVY, spaceAfter=0),
    "note": style("note", fontName="Helvetica", fontSize=7.8, leading=10.5,
                  textColor=INK, alignment=TA_JUSTIFY, spaceAfter=4),
    "small": style("small", fontName="Helvetica", fontSize=7.2, leading=9.5,
                   textColor=MUTED, spaceAfter=3),
}


def section(number, title_fr, title_en):
    """A dark section bar."""
    p = Paragraph(
        f"{number}. {title_fr} &nbsp;&nbsp;<font size=8 color='#C6D5E4'>/ {title_en}</font>",
        S["h2"],
    )
    t = Table([[p]], colWidths=[CONTENT_W], style=TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), NAVY),
        ("LEFTPADDING", (0, 0), (-1, -1), 6),
        ("RIGHTPADDING", (0, 0), (-1, -1), 6),
        ("TOPPADDING", (0, 0), (-1, -1), 4),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
    ]))
    t.spaceBefore = 9
    t.spaceAfter = 5
    return t


def fields(rows, label_w=58 * mm, height=9 * mm):
    """rows: list of (label_fr, label_en, prefilled_value_or_None).

    Rows auto-size to their label, with `height` as the minimum: the empty value
    cell carries an invisible spacer so a one-line label still gets a writable box.
    """
    data = []
    for fr, en, val in rows:
        text = f"{fr}<br/><font name='Helvetica-Oblique' size=7 color='#5A6672'>{en}</font>" if en else fr
        value = [Paragraph(val, S["fill"])] if val else []
        value.append(Spacer(1, height - 6))
        data.append([Paragraph(text, S["label"]), value])
    t = Table(data, colWidths=[label_w, CONTENT_W - label_w])
    t.setStyle(TableStyle([
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("BACKGROUND", (0, 0), (0, -1), BOXBG),
        ("GRID", (0, 0), (-1, -1), 0.5, RULE),
        ("LEFTPADDING", (0, 0), (-1, -1), 5),
        ("RIGHTPADDING", (0, 0), (-1, -1), 5),
        ("TOPPADDING", (0, 0), (-1, -1), 3),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
    ]))
    return t


def grid(header, rows, widths):
    data = [[Paragraph(h, S["cellhead"]) for h in header]]
    for r in rows:
        data.append([Paragraph(c, S["cell"]) for c in r])
    t = Table(data, colWidths=widths, repeatRows=1)
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), HEADBG),
        ("GRID", (0, 0), (-1, -1), 0.5, RULE),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 4),
        ("RIGHTPADDING", (0, 0), (-1, -1), 4),
        ("TOPPADDING", (0, 0), (-1, -1), 3.5),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 3.5),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#FAFBFC")]),
    ]))
    return t


def callout(flows, bg=BOXBG, border=RULE):
    t = Table([[flows]], colWidths=[CONTENT_W], style=TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), bg),
        ("BOX", (0, 0), (-1, -1), 0.6, border),
        ("LEFTPADDING", (0, 0), (-1, -1), 8),
        ("RIGHTPADDING", (0, 0), (-1, -1), 8),
        ("TOPPADDING", (0, 0), (-1, -1), 7),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
    ]))
    t.spaceBefore = 4
    t.spaceAfter = 6
    return t


def checkbox(text_fr, text_en=None):
    """An empty square drawn as a bordered table — Helvetica has no ballot glyph."""
    box = Table([[""]], colWidths=[3.6 * mm], rowHeights=[3.6 * mm], style=TableStyle([
        ("BOX", (0, 0), (-1, -1), 0.8, NAVY),
        ("BACKGROUND", (0, 0), (-1, -1), colors.white),
    ]))
    cell = [Paragraph(text_fr, S["note"])]
    if text_en:
        cell.append(Paragraph(text_en, S["en"]))
    return [box, cell]


def checklist(items):
    t = Table([checkbox(*i) for i in items],
              colWidths=[8 * mm, CONTENT_W - 8 * mm])
    t.setStyle(TableStyle([
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("TOPPADDING", (0, 0), (0, -1), 3),
        ("LEFTPADDING", (0, 0), (-1, -1), 2),
        ("RIGHTPADDING", (0, 0), (-1, -1), 2),
        ("TOPPADDING", (0, 0), (-1, -1), 2),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
    ]))
    return t


def decorate(canvas, doc):
    canvas.saveState()
    # top rule
    canvas.setStrokeColor(NAVY)
    canvas.setLineWidth(1.4)
    canvas.line(MARGIN, PAGE_H - MARGIN + 5 * mm, PAGE_W - MARGIN, PAGE_H - MARGIN + 5 * mm)
    canvas.setFont("Helvetica", 7)
    canvas.setFillColor(MUTED)
    canvas.drawString(MARGIN, PAGE_H - MARGIN + 6.6 * mm,
                      "Déclaration de moyen de cryptologie — ANSSI — "
                      f"{APP_NAME} (iOS)")
    canvas.drawRightString(PAGE_W - MARGIN, PAGE_H - MARGIN + 6.6 * mm,
                           "Apple App Store — Export Compliance")
    # footer
    canvas.setStrokeColor(RULE)
    canvas.setLineWidth(0.5)
    canvas.line(MARGIN, MARGIN - 5 * mm, PAGE_W - MARGIN, MARGIN - 5 * mm)
    canvas.drawString(MARGIN, MARGIN - 9 * mm,
                      "Formulaire à compléter, signer et transmettre à l'ANSSI "
                      "— form to be completed, signed and filed with ANSSI")
    canvas.drawRightString(PAGE_W - MARGIN, MARGIN - 9 * mm, f"Page {doc.page}")
    canvas.restoreState()


def build():
    doc = BaseDocTemplate(
        str(OUT), pagesize=A4,
        leftMargin=MARGIN, rightMargin=MARGIN,
        topMargin=MARGIN, bottomMargin=MARGIN,
        title=f"{APP_NAME} — Déclaration de moyen de cryptologie "
              "(French encryption declaration)",
        author="CribWire",
        subject="Déclaration de fourniture d'un moyen de cryptologie — "
                "LCEN art. 30-II, décret n° 2007-663",
    )
    frame = Frame(MARGIN, MARGIN, CONTENT_W, PAGE_H - 2 * MARGIN, id="body",
                  leftPadding=0, rightPadding=0, topPadding=0, bottomPadding=0)
    doc.addPageTemplates([PageTemplate(id="main", frames=[frame], onPage=decorate)])

    st = []
    A = st.append

    # ------------------------------------------------------------- identity
    A(Paragraph("Déclaration de moyen de cryptologie", S["title"]))
    A(Paragraph("French encryption declaration — approval form for the Apple App Store",
                S["subtitle"]))

    A(fields([
        ("Application concernée", "Application", f"<b>{APP_NAME}</b> — iOS"),
        ("Identifiant de l'application", "Bundle identifier", BUNDLE_ID),
        ("Version déclarée", "Declared version",
         f"{APP_VERSION} (et versions ultérieures sans changement cryptographique)"),
        ("Identifiant équipe Apple", "Apple Team ID", APPLE_TEAM_ID),
        ("Référence ANSSI (après dépôt)",
         "ANSSI reference / receipt no. — fill in once issued", None),
    ], label_w=52 * mm))

    A(callout([
        Paragraph("À quoi sert ce formulaire", S["h3"]),
        Paragraph(
            "L'article 30-II de la loi n° 2004-575 (LCEN) et le décret "
            "n° 2007-663 soumettent à <b>déclaration préalable</b> "
            "auprès de l'ANSSI la fourniture, l'importation ou le transfert d'un "
            "moyen de cryptologie n'assurant pas exclusivement des fonctions "
            "d'authentification ou de contrôle d'intégrité. "
            f"{APP_NAME} chiffre le flux audio/vidéo et les notifications entre "
            "deux appareils appairés : la confidentialité est donc assurée "
            "et la déclaration est requise avant mise à disposition en France.",
            S["body"]),
        Paragraph(
            "Complete and sign this form, file it with ANSSI (téléservice "
            "or postal filing), then upload the signed form together with ANSSI's "
            "acknowledgement of receipt in App Store Connect → App Information "
            "→ Export Compliance, as the French encryption documentation Apple "
            "asks for when the app is distributed in France.",
            S["en"]),
    ]))

    A(section("1", "Identité du déclarant", "Declarant"))
    A(fields([
        ("Raison sociale ou nom", "Legal name of the supplier", None),
        ("Forme juridique", "Legal form", None),
        ("SIREN / SIRET", "Company registration number", None),
        ("Adresse du siège", "Registered address", None),
        ("Code postal, ville, pays", "Postcode, city, country", None),
        ("Représentant légal (nom, fonction)", "Legal representative (name, role)", None),
        ("Courriel", "E-mail", None),
        ("Téléphone", "Telephone", None),
        ("Personne en charge du dossier", "Contact for this file, if different", None),
    ], label_w=58 * mm))

    A(section("2", "Opération déclarée", "Operation being declared"))
    A(checklist([
        ("<b>Fourniture</b> d'un moyen de cryptologie — mise à disposition "
         "du public à titre gratuit via l'Apple App Store.",
         "Supply of a means of cryptology — free distribution to the public "
         "through the Apple App Store."),
        ("Importation depuis un État non membre de l'Union européenne.",
         "Import from a non-EU State."),
        ("Transfert vers un État membre de l'Union européenne.",
         "Transfer to an EU Member State."),
    ]))
    A(fields([
        ("Date de mise à disposition prévue", "Planned availability date", None),
        ("Canal de distribution", "Distribution channel",
         "Apple App Store (iOS, iPadOS) — téléchargement public"),
        ("Territoires", "Territories",
         "Monde entier, France incluse / worldwide, France included"),
    ], label_w=58 * mm))

    # ------------------------------------------------------------ description
    A(section("3", "Description du moyen de cryptologie",
              "Description of the means of cryptology"))
    A(Paragraph(
        f"<b>{APP_NAME}</b> est une application de surveillance de bébé "
        "(babyphone) installée sur deux appareils iOS : l'un, placé près "
        "du lit, filme et écoute la chambre — l'autre, gardé par le "
        "parent, reçoit le flux. L'appairage se fait <b>hors ligne</b> : "
        "l'appareil émetteur affiche un QR code contenant un secret aléatoire "
        "de 32 octets, que l'appareil récepteur photographie. Toutes les clés "
        "sont dérivées de ce secret ; le serveur ne le connaît jamais.",
        S["body"]))
    A(Paragraph(
        "La cryptographie a une <b>fonction unique et accessoire</b> : garantir que "
        "le flux audio/vidéo d'une chambre d'enfant et les notifications "
        "associées ne soient lisibles que par les deux appareils appairés. "
        "L'application n'offre aucune fonction de chiffrement à l'utilisateur, "
        "n'expose aucune API cryptographique et ne permet pas de chiffrer des "
        "fichiers ou des messages arbitraires. Le serveur de signalisation et le "
        "relais TURN ne transportent que du chiffré et ne détiennent aucune "
        "clé de déchiffrement.",
        S["body"]))
    A(Paragraph(
        "Encryption serves one incidental purpose: keeping a nursery's audio/video "
        "stream and its alerts readable only by the two paired devices. The app "
        "exposes no cryptographic API to the user and cannot encrypt arbitrary "
        "files or messages. The signalling server and TURN relay carry ciphertext "
        "only and hold no decryption key.",
        S["en"]))

    A(section("4", "Fonctions cryptographiques mises en œuvre",
              "Cryptographic functions implemented"))
    A(grid(
        ["Fonction / Function", "Algorithme", "Longueur de clé",
         "Rôle dans l'application", "Mise en œuvre"],
        [
            ["Génération d'aléa",
             "CSPRNG du système (<i>SecRandomCopyBytes</i>)", "256 bits",
             "Secret racine porté par le QR code, nonces",
             "Apple Security.framework"],
            ["Dérivation de clés", "HKDF-SHA-256", "256 bits",
             "Dérive les quatre clés de session depuis le secret du QR code",
             "Apple CryptoKit"],
            ["Chiffrement authentifié — signalisation",
             "ChaCha20-Poly1305 (AEAD)", "256 bits",
             "Scelle les offres/réponses SDP et les candidats ICE de bout en bout",
             "Apple CryptoKit"],
            ["Chiffrement authentifié — notifications",
             "ChaCha20-Poly1305 (AEAD)", "256 bits",
             "Scelle le contenu des notifications push avant envoi à APNs",
             "Apple CryptoKit"],
            ["Authentification de messages", "HMAC-SHA-256", "256 bits",
             "Authentifie les appels API et la session WebSocket ; code de "
             "confirmation à six chiffres",
             "Apple CryptoKit / Node.js <i>crypto</i>"],
            ["Chiffrement du flux média",
             "DTLS 1.2+ / SRTP (AES-128-GCM, AES-128-CTR + HMAC-SHA-1)",
             "128 bits",
             "Chiffre l'audio et la vidéo entre les deux appareils ; l'empreinte "
             "du certificat DTLS est liée au secret du QR code",
             "WebRTC (<i>libwebrtc</i>)"],
            ["Sécurisation du transport", "TLS 1.2 / 1.3", "128–256 bits",
             "HTTPS et WebSocket sécurisé vers le serveur de signalisation",
             "Piles du système (URLSession / Network.framework)"],
        ],
        widths=[30 * mm, 36 * mm, 20 * mm, 51 * mm, 37 * mm]))
    A(Spacer(1, 4))
    A(Paragraph(
        "<b>Aucun algorithme propriétaire ou non standard n'est utilisé.</b> "
        "Toutes les primitives sont publiques, normalisées (NIST, IETF) et "
        "appelées via les bibliothèques du système d'exploitation ou "
        "WebRTC ; aucune implémentation cryptographique n'a été "
        "écrite par l'éditeur. "
        "<i>No proprietary or non-standard algorithm is used; every primitive is "
        "public, standardised and called through operating-system or WebRTC "
        "libraries.</i>",
        S["note"]))

    keys = grid(
        ["Élément / Item", "Réponse"],
        [
            ["Génération",
             "Sur l'appareil émetteur, à chaque appairage, par le "
             "générateur aléatoire du système. Aucune clé "
             "n'est produite ni conservée par l'éditeur."],
            ["Échange",
             "Hors bande, par lecture d'un QR code affiché à l'écran. "
             "Aucun échange de clé ne transite par le réseau."],
            ["Stockage",
             "Trousseau iOS (Keychain), attribut "
             "<i>kSecAttrAccessibleWhenUnlockedThisDeviceOnly</i> ; exclu de la "
             "synchronisation iCloud et des sauvegardes."],
            ["Séquestre / recouvrement",
             "<b>Aucun.</b> Ni l'éditeur, ni l'hébergeur, ni Apple ne "
             "détiennent de clé permettant de déchiffrer un flux ou "
             "une notification."],
            ["Renouvellement",
             "Le QR code est régénéré toutes les deux minutes ; "
             "un nouvel appairage remplace l'intégralité des clés."],
            ["Révocation et effacement",
             "La suppression d'un appairage efface les clés du trousseau sur "
             "l'appareil et la clé d'authentification côté serveur."],
        ],
        widths=[38 * mm, CONTENT_W - 38 * mm])
    A(KeepTogether([section("5", "Gestion des clés", "Key management"), keys]))

    # ------------------------------------------------------ classification
    A(section("6", "Classement au regard des biens à double usage",
              "Dual-use classification"))
    A(Paragraph(
        "Règlement (UE) 2021/821, annexe I, catégorie 5 partie 2 — "
        "position proposée (à confirmer par le conseil de l'éditeur) :",
        S["body"]))
    A(checklist([
        ("<b>5A002.a</b> — système utilisant un chiffrement symétrique "
         "de plus de 56 bits, revendiquant le bénéfice de la <b>note de "
         "cryptologie</b> (note 3) : logiciel grand public, distribué sans "
         "restriction par téléchargement, dont la fonction cryptographique "
         "ne peut être modifiée par l'utilisateur.",
         "Mass-market software under the Cryptography Note (Note 3): freely "
         "downloadable, with a cryptographic function the user cannot modify."),
        ("Autre classement — préciser : "
         "________________________________________________", None),
    ]))
    A(Paragraph(
        "Réponses correspondantes dans App Store Connect — "
        "<i>matching answers in App Store Connect</i> :", S["h3"]))
    A(grid(
        ["Question Apple", "Réponse", "Motif / Reason"],
        [
            ["L'application utilise-t-elle du chiffrement ?<br/>"
             "<i>Does your app use encryption?</i>",
             "Oui / Yes",
             "Chiffrement de bout en bout du flux et des notifications "
             "(<i>ITSAppUsesNonExemptEncryption</i> = <b>YES</b>)."],
            ["Le chiffrement est-il exempté ?<br/>"
             "<i>Does it qualify for an exemption?</i>",
             "À confirmer / To confirm",
             "L'application n'utilise pas uniquement le chiffrement fourni par "
             "iOS : elle appelle ChaCha20-Poly1305 et HKDF via CryptoKit sur ses "
             "propres clés. À valider avec le conseil juridique."],
            ["Documentation française<br/><i>French declaration documents</i>",
             "Ce formulaire + accusé de réception ANSSI",
             "À téléverser dans App Store Connect → App "
             "Information → Export Compliance."],
        ],
        widths=[46 * mm, 34 * mm, CONTENT_W - 80 * mm]))

    A(section("7", "Pièces jointes au dossier", "Enclosures"))
    A(checklist([
        ("Description technique détaillée du moyen de cryptologie "
         "(spécification de sécurité de l'application).",
         "Detailed technical description — the app's security specification."),
        ("Extrait Kbis ou preuve d'immatriculation du déclarant.",
         "Proof of company registration."),
        ("Fiche descriptive commerciale de l'application (page App Store).",
         "Product/marketing description — the App Store listing."),
        ("Le cas échéant, mandat du représentant signataire.",
         "Where applicable, the signatory's power of attorney."),
    ]))

    sign = []
    B = sign.append
    B(section("8", "Engagement et signature", "Declaration and signature"))
    B(Paragraph(
        "Je soussigné(e), agissant en qualité de représentant légal "
        "du déclarant désigné en section 1, certifie exactes et "
        "complètes les informations portées sur le présent formulaire "
        "et ses annexes, et m'engage à déclarer à l'ANSSI toute "
        "modification des fonctions cryptographiques décrites en section 4.",
        S["body"]))
    B(Paragraph(
        "I certify that the information given in this form and its enclosures is "
        "accurate and complete, and undertake to notify ANSSI of any change to the "
        "cryptographic functions described in section 4.",
        S["en"]))
    B(Spacer(1, 2))
    B(fields([
        ("Nom et prénom", "Name", None),
        ("Qualité", "Position", None),
        ("Fait à", "Place", None),
        ("Le", "Date", None),
    ], label_w=45 * mm, height=11 * mm))
    B(Spacer(1, 2))
    sig = Table(
        [[Paragraph("Signature du déclarant<br/>"
                    "<font name='Helvetica-Oblique' size=7 color='#5A6672'>Signature</font>", S["label"]),
          Paragraph("Cachet de l'entreprise<br/>"
                    "<font name='Helvetica-Oblique' size=7 color='#5A6672'>Company stamp</font>", S["label"])]],
        colWidths=[CONTENT_W / 2, CONTENT_W / 2], rowHeights=[30 * mm])
    sig.setStyle(TableStyle([
        ("GRID", (0, 0), (-1, -1), 0.5, RULE),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 5),
        ("TOPPADDING", (0, 0), (-1, -1), 4),
    ]))
    B(sig)

    A(KeepTogether(sign))
    A(Spacer(1, 8))
    A(KeepTogether(callout([
        Paragraph("Avertissement — Disclaimer", S["h3"]),
        Paragraph(
            "Ce document est un formulaire préparé par l'éditeur à "
            "partir de la documentation technique de l'application. Il ne constitue "
            "ni une autorisation, ni un agrément, ni un accusé de "
            "réception de l'ANSSI : ces derniers ne peuvent être "
            "délivrés que par l'ANSSI après dépôt du dossier. "
            "Le classement proposé en section 6 doit être validé par un "
            "conseil compétent avant dépôt.",
            S["note"]),
        Paragraph(
            "This is a self-prepared declaration form, not an ANSSI approval, "
            "authorisation or receipt — only ANSSI can issue those, once the "
            "file has been submitted. Have the classification in section 6 confirmed "
            "by qualified counsel before filing.",
            S["en"]),
    ], bg=colors.HexColor("#FFF8E8"), border=colors.HexColor("#E0C88A"))))

    doc.build(st)
    print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    build()
