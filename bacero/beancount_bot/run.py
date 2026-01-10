import asyncio
import logging
import re
import sys
from os import getenv
from typing import Any

from aiogram import BaseMiddleware, Bot, Dispatcher, F, Router, html
from aiogram.client.default import DefaultBotProperties
from aiogram.dispatcher.event.bases import SkipHandler
from aiogram.enums import ParseMode
from aiogram.filters import Command, CommandStart
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import (KeyboardButton, Message, ReplyKeyboardMarkup,
                           ReplyKeyboardRemove)
from aiogram.types.bot_command import BotCommand

from local_db import (archive_all_transactions, delete_last_transaction,
                      get_last_transaction, get_most_frequent_by_field,
                      get_transactions, init_db, insert_transaction)

DB_HOST = '/run/postgresql'
DB_NAME = 'beancount_bot'
DB_USER = 'beancount_bot'

TOKEN = getenv("BOT_TOKEN")
ALLOWED_USERS = [
    int(chat_id)
    for chat_id
    in getenv("ALLOWED_USERS").split(',')
]

class AuthMiddleware(BaseMiddleware):
    async def __call__(self, handler, event, data):
        if event.from_user.id in ALLOWED_USERS:
            return await handler(event, data)
        else:
            logging.warning(f'Unexpected user: {event.from_user.id}')


form_router = Router()
form_router.message.middleware(AuthMiddleware())


class InsertionForm(StatesGroup):
    idle = State()
    amount_set = State()
    description_set = State()
    source_set = State()


amount_pattern = re.compile(r'^(\d+)(\.(\d+))?( ([A-Z][A-Z0-9\.\-_]+))?$')

def parse_amount(message_text, default_currency):
    groups = amount_pattern.match(message_text)
    if groups:
        integer_part = int(groups[1])
        cent_part = int(groups[3] or '0')
        currency_part = groups[5] or default_currency

        return integer_part, cent_part, currency_part


def parse_account_name(message_text):
    removed_extra_spaces = re.sub(r'\s+', ' ', message_text.strip())
    return removed_extra_spaces.replace(' ', ':')


async def get_field_suggestions(user_id, field_id, n=12):
    common_fields = await get_most_frequent_by_field(user_id, field_id, n)
    last_entry = await get_last_transaction(user_id)

    if last_entry and last_entry[field_id] not in common_fields:
        common_fields = [last_entry[field_id], *common_fields[:-1]]

    markup = ReplyKeyboardMarkup(
        keyboard=[ [KeyboardButton(text=label) for label in common_fields] ],
        resize_keyboard=True)

    return markup


@form_router.message(Command("cancel"))
async def cancel_insertion(message: Message, state: FSMContext) -> None:
    current_state = await state.get_state()
    if current_state is None:
        return

    await state.clear()
    await message.answer("Inserimento annullato.", reply_markup=ReplyKeyboardRemove())


def db_transaction_to_beancount(db_trans):
    insert_time = db_trans['insert_time']
    insert_date = insert_time.date()

    amount_integer = db_trans['amount_cent'] // 100
    amount_cents = db_trans['amount_cent'] % 100

    currency = db_trans['currency']
    source_account = db_trans['source_account']
    destination_account = db_trans['destination_account']
    description = db_trans['description']

    account_max_len = max(len(source_account), len(destination_account))
    padded_source_account = source_account.ljust(account_max_len)
    padded_destination_account = destination_account.ljust(account_max_len)

    lines = [
        f'{insert_date} * "{description}"',
        f'  {padded_source_account}  -{amount_integer}.{amount_cents:02} {currency}',
        f'  {padded_destination_account}',
    ]

    return '\n'.join(lines)


async def send_list_of_transactions(message, archived=False):
    transactions = await get_transactions(message.from_user.id, archived=archived)
    descriptions = map(db_transaction_to_beancount, transactions)

    combined_description = '\n\n'.join(descriptions)
    if combined_description:
        combined_description = '```\n' + combined_description + '\n```'
    else:
        combined_description = 'Nessuna transazione presente'

    await message.answer(combined_description, parse_mode='MarkdownV2')

    return transactions


@form_router.message(Command("list"))
async def list_active_transactions(message: Message, state: FSMContext) -> None:
    user_id = message.from_user.id
    state_id = await state.get_state()

    # state is None before inserting
    if state_id is None or state_id == InsertionForm.idle:
        await send_list_of_transactions(message, archived=False)
    else:
        await message.answer("Comando non valido durante un inserimento")


@form_router.message(Command("list_archived"))
async def list_archived_transactions(message: Message, state: FSMContext) -> None:
    chat_id = message.chat.id
    user_id = message.from_user.id
    state_id = await state.get_state()

    # state is None before inserting
    if state_id is None or state_id == InsertionForm.idle:
        await send_list_of_transactions(message, archived=True)
    else:
        await message.answer("Comando non valido durante un inserimento")


@form_router.message(Command("archive"))
async def archive_transactions(message: Message, state: FSMContext) -> None:
    user_id = message.from_user.id
    state_id = await state.get_state()

    # state is None before inserting
    if state_id is None or state_id == InsertionForm.idle:
        await send_list_of_transactions(message, archived=False)
        await archive_all_transactions(user_id)
        await message.answer("Transazioni archiviate")
    else:
        await message.answer("Comando non valido durante un inserimento")


@form_router.message(Command("delete_last"))
async def delete_last_trans(message: Message, state: FSMContext) -> None:
    user_id = message.from_user.id
    state_id = await state.get_state()

    # state is None before inserting
    if state_id is None or state_id == InsertionForm.idle:
        active_transations = await send_list_of_transactions(message, archived=False)

        if active_transations:
            await delete_last_transaction(user_id)
            await message.answer("Rimossa l'ultima transazione")
    else:
        await message.answer("Comando non valido durante un inserimento")


@form_router.message(InsertionForm.amount_set)
async def description_setter(message: Message, state: FSMContext) -> None:
    await state.update_data(description=message.text)
    await state.set_state(InsertionForm.description_set)

    markup = await get_field_suggestions(message.from_user.id, 'source_account')
    await message.answer("Account di origine:", reply_markup=markup)


@form_router.message(InsertionForm.description_set)
async def source_account_setter(message: Message, state: FSMContext) -> None:
    source_account = parse_account_name(message.text)
    await state.update_data(source_account=source_account)
    await state.set_state(InsertionForm.source_set)

    markup = await get_field_suggestions(message.from_user.id, 'destination_account')
    await message.answer("Account di destinazione:", reply_markup=markup)


@form_router.message(InsertionForm.source_set)
async def destination_account_setter(message: Message, state: FSMContext) -> None:
    destination_account = parse_account_name(message.text)
    await state.update_data(destination_account=destination_account)

    insertion_form_data = await state.get_data()
    await state.clear()

    amount_cent = insertion_form_data['amount_cent']
    source_account = insertion_form_data['source_account']
    destination_account = insertion_form_data['destination_account']
    description = insertion_form_data['description']
    currency = insertion_form_data['currency']

    await insert_transaction(message.from_user.id,
                             amount_cent, currency,
                             source_account, destination_account,
                             description)

    amount_formatted = f'{amount_cent // 100}.{amount_cent % 100:02} {currency}'

    await message.answer(
        f"{description} | {amount_formatted}\n{source_account} ➜ {destination_account}",
        reply_markup=ReplyKeyboardRemove()
    )

    await state.set_state(InsertionForm.idle)


@form_router.message()
async def insertion_entrypoint(message: Message, state: FSMContext) -> None:
    parsed_amount = parse_amount(message.text, 'EUR')

    if parsed_amount is None:
        error_message = f'Il messaggio non contiene una somma valida: "{message.text}"'
        await message.answer(error_message, reply_markup=ReplyKeyboardRemove())
        return

    integer_part, cent_part, currency = parsed_amount

    await state.update_data(amount_cent=integer_part * 100 + cent_part)
    await state.update_data(currency=currency)

    await state.set_state(InsertionForm.amount_set)

    await message.answer("Descrizione:", reply_markup=ReplyKeyboardRemove())


async def main() -> None:
    await init_db()

    bot = Bot(token=TOKEN, default=DefaultBotProperties(parse_mode=ParseMode.HTML))
    await bot.set_my_commands([
        BotCommand(command="cancel", description="Annulla l'inserimento della transazione"),
        BotCommand(command="archive", description="Archivia tutte le transazioni"),
        BotCommand(command="list", description='Elenca tutte le transazione attive'),
        BotCommand(command="list_archived", description='Elenca tutte le transazione archiviate'),
        BotCommand(command="delete_last", description='Rimuovi l\'ultima transazione'),
    ])

    dp = Dispatcher()
    dp.include_router(form_router)

    await dp.start_polling(bot)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, stream=sys.stdout)
    asyncio.run(main())
